# 07 · Retrieval and Ranking Models: Phoenix, Two-Tower, DPP and Index Admission

> Evidence base: `phoenix/xrex/*`, `home-mixer/*`, `thunder/*`, `simclusters/*`, `vm-ranker/*`, `phoenix-rankall*/*`, commit `a284320b66a9dce35e6f5d6b052ee308eeb12326`.
> Division of labour: **all weight values live in `02-scoring-ranking.md`** (`vm-ranker/params.rs` carries no sync stamp and its defaults are stale, so this document does not reproduce a weight table); per-filter semantics live in `03-retrieval-filtering.md`. This document covers model structure, training objectives and index admission only.
> Labelling convention: **production default** = current config value; **code present but off** = the path exists but the switch is off or the weight is 0; **not public** = not findable in the repo.

---

## 1. The end-to-end funnel (real numbers)

The pipeline lives in `home-mixer/candidate_pipeline/phoenix_candidate_pipeline.rs`, in the order query_hydrators → sources → hydrators → filters → scorers → selector → post_selection_hydrators → post_selection_filters.

| Stage | Content | Evidence |
|---|---|---|
| sources (9, in this order) | thunder, popular_posts, tweet_mixer, simclusters, phoenix, phoenix_topics, phoenix_moe, sid, cached_posts | `phoenix_candidate_pipeline.rs:385-395` |
| filters (**21**, before scoring) | DropDuplicates → ZeroFavCodivert → CoreDataHydration → NewUserSoftNsfw → Age(48h) → SelfTweet → OONRetweetReply → OONNsfwSimclusters → RetweetDedup → IneligibleSubscription → PreviouslySeen×2 → PreviouslyServed → ViewerMutedKeyword → AuthorSocialgraph → Video → TopicIds → NewUserMinEngagement → InventoryHoldout → FavHoldout → **FairShareRanking** | `phoenix_candidate_pipeline.rs:432-456` |
| **scoring budget 2800** | `FairShareRankingFilter` allocates `PhoenixScoresResultSize=2800` proportionally by `served_type` (largest-remainder method); the client then applies `.take(2800)` as a backstop | `filters/fair_share_ranking_filter.rs:29-32,59-101`; `params/param.rs:1509-1520`; `util/phoenix_request.rs:20,204` |
| scorers | PhoenixScorer → ImmersiveVideoScorer → **VMRanker** → PageDecodeRerank → PageRlExploration | `phoenix_candidate_pipeline.rs:481-487` |
| selector | `TopKScoreSelector`: take **50** by descending `candidate.score` | `selectors/top_k_score_selector.rs:15-17,32-38`; `params/config.rs:19` |
| post_selection_filters (5) | **VFFilter** → AncillaryVFFilter → AncestorVideoFilter → DedupConversationFilter → VideoCarouselFilter | `phoenix_candidate_pipeline.rs:515-521` |
| final count | `RESULT_SIZE = 35`; the outer For You layer uses `FOR_YOU_MAX_RESULT_SIZE = 35 + 5 + 8 = 48` | `phoenix_candidate_pipeline.rs:1153-1155`; `params/config.rs:20-24` |

Two things that are easy to misread:

1. **Visibility filtering (VF) appears twice**: once at **offline index admission** (`phoenix-rankall-strato`, deciding whether a post can enter the retrieval pool at all, §11), and once **online after the top-50** (`VFFilter`, deciding whether it can actually be shown). Both use safety level `TimelineHomeRecommendations`, but the contexts are completely different.
2. **`VFFilter` does not deduct score**: `Drop(_) | Tombstone | NotEvaluated` are discarded, `Allow | Interstitial | Avoid | Downrank` are kept (`home-mixer/filters/vf_filter.rs:22-27`). **Downrank is merely passed through at this step**; the downweighting happens elsewhere.

---

## 2. Phoenix is pointwise, not listwise: the candidate-isolation mask

The single most important architectural fact in this document. `phoenix/xrex/pallas/ranker_attention_utils.py:54-56`:

```python
history_mask        = kv_is_history & (q_is_history | q_is_candidate)
candidate_self_mask = q_is_candidate & kv_is_candidate & (q_pos == kv_pos)
return history_mask | candidate_self_mask
```

`q_pos == kv_pos` **completely cuts attention between candidates**: each candidate can only see the user prefix + history + **itself**. The boundary is `history_upper = num_user_prefix_tokens + history_seq_len` (`phoenix/xrex/models/recsys_attention.py:39-42,110-113`); the CuTeDSL FA4 kernel matches this with `fwd_diag_cnt = is_cand` and `fwd_diag_idx = t` (`phoenix/xrex/cutedsl/ranker_attention_fa4.py:79-80`, block=128). In RoPE, **all candidates share the same position `history_end`** (`phoenix/xrex/models/recsys_model.py:277-298`), so there is no positional ordering among candidates.

**Conclusion: Phoenix scores every post independently — "this post vs your history" — and candidates cannot see each other.** Therefore:

- the model will **not** suppress a 4th post because "this screen already has 3 posts from the same author";
- all slate / diversity effects come from outside the model: DPP (§10), author-diversity decay and the OON discount (`xai-value-model/scoring.rs`; values in `02-scoring-ranking.md`);
- slate context is only a **return field**: `served_slate_context` is taken out of the prediction result and attached to the candidate (`home-mixer/scorers/phoenix_scorer.rs:145-147`); it is not a scoring input.

---

## 3. Production architecture and hyperparameters (config name `home_direct_packed`)

Base `phoenix/xrex/configs/xrecsys.py:318-386`, production override `:545-590`, attention/FFN assembly `:1046-1084`.

| Item | Production value | Evidence |
|---|---|---|
| sequence layout | `history_seq_len=1022` + `num_user_prefix_tokens=2` (`enable_user_embedding + has_user_features`) = user segment **1024** (forced power of two); `candidate_seq_len=64`; total serving length **1088** | `xrecsys.py:318-386,797-801,58-70,256-262` |
| backbone | `num_layers=8`, `emb_size=2560`, `emb_table_width=1024` (table width 1024 projected up to 2560) | `xrecsys.py:318-386` |
| attention | `query_heads=20` / `kv_heads=4` (**GQA 5:1**) / `key_size=128`; **`causal=False`**; `rotary=True` + **`right_anchored_rope=True`**; **`qk_norm=True`**; `attn_logit_cap=-1` (disabled; framework default is 80.0 + `soft_sign`) | `xrecsys.py:318-386,1046-1084` |
| FFN | `widening_factor=2`, `gated_mlp=False` | `xrecsys.py:1046-1084` |
| candidate-only layers | **2 layers**, `candidate_only_attn_impl="cutedsl_ranker_candidate_only_attn"` | `xrecsys.py:545-590` |
| seqpack | `use_seqpack=True`, `BetaLengthDistribution(min_len=126, max_len=1022, mean_len=510→414 in production, alpha=1.0, beta=1.0, block_size=128)`, `seqpack_candidate_count=[128]` | `xrecsys.py:378-385,551-553,545-590` |
| H100 training | `bs_per_device=1024`, `num_microbatch=8`, `ep=64`, `lr=7.1e-4`, Muon(`b1=0.95, b2=0.98, consistent_rms=0.2, matrix_weight_decay=0.014, split_fused="qkv:128"`), embedding row-wise Adagrad(`lr=0.28, half_life_steps=2500`), `fp8_gemms=ALL`, `clip_by_global_norm=1.4` | `xrecsys.py:389-418,545-590` |

**The training sequence is longer than serving**: `_sequence_len` also multiplies in negative-candidate blocks `(1 + num_negatives_per_example)` (`xrecsys.py:256-262`), and the ranking dataset defaults that value to **1** (`phoenix/xrex/data/parquet_recsys.py:1943`), which `home_direct_packed` does not override. 1088 is the **inference layout**.

Local smoke config `home_direct_packed_nano`: `emb_size=512, num_layers=4, query_heads=4, kv_heads=2, emb_table_width=128` (`xrecsys.py:619-642`), served with `--history_seq_len 128 --candidate_seq_len 16` and `sequence_len=146` (`phoenix/QUICKSTART.md:128-151`). **For getting a local run working only, not production scale.**

---

## 4. Prediction heads: 60 discrete actions + 8 continuous values

`output_vocab_size = round_up(ACTION_TYPE_MAP_LEN=60, OUTPUT_VOCAB_K=64) = 64` (`xrecsys.py:48-51,156-158`). **The head index is exactly the `ActionName` enum value: 0..59 are valid, 60..63 are padding.** Enum values 60 and above (`CLIENT_TWEET_EXTERNAL_LINK_LONG_DWELLED=60` … `CLIENT_TWEET_SWIPE_TO_PROFILE=115`, plus the ADS block 128-213+) are **history input actions only, not prediction targets**.

All 60 heads (`phoenix/python/common/xai-proto/proto/recsys.proto:519-579`):

```
0  INVALID_NAME                             20 CLIENT_TWEET_UNDO_SEE_FEWER            40 CLIENT_TWEET_TAKE_SCREENSHOT
1  SERVER_TWEET_FAV                         21 CLIENT_TWEET_FOLLOW_AUTHOR             41 CLIENT_TWEET_TRANSLATE_CLICK
2  SERVER_TWEET_UNFAV                       22 CLIENT_TWEET_UNFOLLOW_AUTHOR           42 CLIENT_TWEET_NOT_RELEVANT
3  SERVER_TWEET_CREATE                      23 CLIENT_TWEET_BLOCK_AUTHOR              43 CLIENT_TWEET_UNDO_NOT_RELEVANT
4  SERVER_TWEET_REPLY                       24 CLIENT_TWEET_UNBLOCK_AUTHOR            44 SERVER_TWEET_POST_VIDEO
5  SERVER_TWEET_QUOTE                       25 CLIENT_TWEET_MUTE_AUTHOR               45 CLIENT_TWEET_SHOW_MORE_EXPAND
6  SERVER_TWEET_RETWEET                     26 CLIENT_TWEET_UNMUTE_AUTHOR             46 CLIENT_TWEET_CLICK_GROK_ANALYZE
7  SERVER_TWEET_UNREPLY                     27 CLIENT_TWEET_MUTE_CONVERSATION         47 CLIENT_TWEET_VIDEO_OPEN
8  SERVER_TWEET_UNQUOTE                     28 CLIENT_TWEET_UNMUTE_CONVERSATION       48 CLIENT_QUOTED_TWEET_VIDEO_QUALITY_VIEW
9  SERVER_TWEET_UNRETWEET                   29 CLIENT_TWEET_CLICK                     49 CLIENT_QUOTED_TWEET_PHOTO_EXPAND
10 SERVER_TWEET_REPORT                      30 CLIENT_TWEET_CLICK_PROFILE             50 CLIENT_NOTIFICATION_OPEN
11 CLIENT_TWEET_RECAP_DWELLED               31 CLIENT_TWEET_CLICK_SHARE               51 CLIENT_NOTIFICATION_CLICK
12 CLIENT_TWEET_RECAP_NOT_DWELLED           32 CLIENT_TWEET_SHARE_VIA_COPY_LINK       52 CLIENT_NOTIFICATION_SEE_LESS_OFTEN
13 CLIENT_TWEET_VIDEO_QUALITY_VIEW          33 CLIENT_TWEET_CLICK_SEND_VIA_DIRECT_MESSAGE 53 CLIENT_NOTIFICATION_DISMISS
14 CLIENT_TWEET_PHOTO_EXPAND                34 CLIENT_TWEET_UNBOOKMARK                54 CLIENT_APP_ENTER
15 CLIENT_TWEET_CLICK_MENTION_SCREEN_NAME   35 CLIENT_TWEET_CLICK_HASHTAG             55 CLIENT_APP_EXIT
16 CLIENT_TWEET_REPORT                      36 CLIENT_TWEET_BOOKMARK                  56 CLIENT_NOTIFICATION_IMPRESSION
17 CLIENT_TWEET_NOT_INTERESTED_IN           37 CLIENT_TWEET_SHARE                     57 CLIENT_PROFILE_CLICK
18 CLIENT_TWEET_UNDO_NOT_INTERESTED_IN      38 CLIENT_QUOTED_TWEET_CLICK              58 CLIENT_NOTIFICATION_SENT
19 CLIENT_TWEET_SEE_FEWER                   39 CLIENT_TWEET_OPEN_LINK                 59 SERVER_TWEET_POST_UNEXPLORED
```

The 8 continuous heads (`recsys.proto:764-773`; `num_continuous_actions=8`, `continuous_action_hidden_dim=64`, `recsys_model.py:1388`): `HOME_PROFILE_VISIT_SECS=0`, `DWELL_TIME=1`, `CLICK_DWELL_TIME=2`, `HOME_VIDEO_CONTINUATION_SECS=3`, `BRIDGE_PROBABILITY=4`, `ADS_WEB_CT_PURCHASE_VALUE=5`, `ADS_VIDEO_WATCH_TIME_SECS=6`, `ADS_VIDEO_LENGTH_SECS=7`.

Decoding: discrete `logits = out_embeddings @ unembeddings` (`recsys_model.py:3487-3490`); continuous goes through `continuous_unembeddings` (`:3493-3509,3684-3775`). **This is what "multi-action prediction" concretely means**: one forward pass emits 60 action probabilities + 8 continuous values per candidate, and the weighted sum into a final score happens in the value model (`02-scoring-ranking.md`).

---

## 5. Loss: discrete BCE + CREAD dwell time

Total loss = Σ discrete multihot + Σ continuous + activation L2 (`act_l2_weight=5e-7`, `xrecsys.py:882`; aggregation at `recsys_model.py:5501-5506`).

### 5.1 Discrete heads

`phoenix/xrex/models/loss_recsys.py:21-55`: per-action `optax.sigmoid_binary_cross_entropy`, multiplied by `padding_mask * loss_mask`, then divided by `sum(mask*weights)`.

| Mechanism | Production value | Evidence |
|---|---|---|
| `view_loss_weight` | **0.5**, applied to `VIEW_LOSS_ACTION_INDICES = {RECAP_DWELLED, RECAP_NOT_DWELLED, VIDEO_QUALITY_VIEW}` | `xrecsys.py:545-590`; `data/recsys/constants.py:566-570`; `recsys_model.py:5294-5300` |
| conditional head weights | `home_video_continuation_loss_weight=0.013`, `home_profile_visit_secs_loss_weight=0.0035` | `xrecsys.py:545-590` |
| negative-feedback heads masked on negatives | `mask_neg_feedback_on_negatives=True` | `recsys_model.py:1478,5273-5278` |
| mask a candidate's positive labels when a negative action is present | `mask_candidate_positive_when_negative_action_present` | `recsys_model.py:5235-5268` |
| logQ correction | `log_q_correction=True`, `log_q_num_bins=100_000_000` | `xrecsys.py:838` |
| new-user test | `new_user_mask = history event count < 128` | `recsys_model.py:5066,5221` |

### 5.2 Dwell time = CREAD (classification + restoration), not regression on a number of seconds

Generic continuous-head normalization is `gt_norm = clip(gt, 0, norm_scale)/norm_scale` (`loss_recsys.py:68-107`). CREAD adds two steps on top — geometric thresholds (`loss_recsys.py:110-125`) plus classification and restoration losses (`:128-187`):

```
ratio       = norm_scale / log_min_threshold
thresholds[k] = log_min_threshold * ratio^(k/(num_thresholds-1)), k=0..K-2; norm_scale appended at the end
targets_k   = 1[gt > threshold_k]
cls         = mean_k BCE(sigmoid(logit_k), targets_k)
restored    = Σ_k sigmoid(logit_k) * delta_k,  delta_k = scale*(t_k^p − t_{k−1}^p)
              # _decode_cread, recsys_model.py:3639-3681
restoration = huber(|restored − clip(gt,0,norm_scale)| / norm_scale,
                    delta = cread_huber_delta_sec / norm_scale)
loss        = cls + restoration_weight * restoration
```

That is, **30 binary classifiers of the form "did dwell exceed t_k seconds" + one Huber auxiliary term that restores the classification probabilities back into seconds**. This is where the 2026-10-08 "improved dwell-time prediction" changelog entry lands in code.

| Variant | Key parameters | Production loss weight | Evidence |
|---|---|---|---|
| `dwell-time-cread` | `norm_scale=120.0`, **excludes GALLERY** | **0.1** | `xrecsys.py:885-943,339` |
| `dwell-time-cread-immersive` | `norm_scale=240.0`, **GALLERY only** | **0.1** | `xrecsys.py:885-943,340` |
| `click-dwell-binary` | `binary_threshold=10.0` seconds, `norm_scale=60.0` | **1.0** | `xrecsys.py:336`; assembly `:909` |
| `dwell-time-tweedie` | `tweedie_power=1.5`, `output_cap=300.0`, GALLERY only, norm 300 | **0.0 (off)** | `xrecsys.py:337`; `loss_recsys.py:215-246` |
| `dwell-time-mae` | norm 30 | **0.0 (off)** | `xrecsys.py:338` |

**Erratum**: the fallback for `click-dwell-binary` is 0.0 (`mparams.get("click_dwell_loss_weight", 0.0)` at `xrecsys.py:909`), but the production base explicitly sets **1.0** (`xrecsys.py:336`) and `home_direct_packed` does not override it — **reading only the fallback misclassifies this head as "off"**. Only the `immersive_page_rl` family sets it to 0.0 (`xrecsys.py:464`).

CREAD generic defaults: `log_min_threshold=2.0`, `num_thresholds=30`, `restoration_weight=0.5`, `restoration_loss="huber"`, `huber_delta_sec=5.0` (`recsys_model.py:458-541`). Conditional continuous heads: `HOME_VIDEO_CONTINUATION_SECS` (idx 3) is conditioned on `CLIENT_TWEET_VIDEO_OPEN`, `HOME_PROFILE_VISIT_SECS` (idx 0) on `CLIENT_TWEET_CLICK_PROFILE`, both also CREAD with `norm_scale=300.0` (`xrecsys.py:269-315`) — **samples where the conditioning action did not occur do not contribute to these two heads' loss**.

### 5.3 In-model safety filtering: off in production

`safety_filter_mode ∈ {off, hard, soft}`, production **`"off"`**; `safety_filter_bits=0b11`, `soft_weight=0.0`, `apply_to_candidates=True`, `apply_to_history=False` (`recsys_model.py:1507-1511`). Implementation: `hard` → `padding_mask & ~flagged`; `soft` → multiply the weight by `soft_weight` (`phoenix/xrex/data/recsys/safety_filter.py:23-35`). **This is a training/scoring-side switch; online risk control relies on VF, not on this.** Which labels the two bits correspond to is **not public** (`safetyLabelMaskSeq` is just an int64 column, `data/recsys/feature_config.py:164-208`).

---

## 6. The retrieval two-tower: the user side is a transformer, the tweet side is not

Config `phoenix/xrex/configs/xrecsys_two_tower.py:252-351`.

| Component | Structure | Evidence |
|---|---|---|
| **user tower** | 8-layer transformer, `emb_size=1024`, `emb_table_width=1024`, `query_heads=16`, `kv_heads=4`, `history_seq_len=1023`, `effective_sequence_len=513`, `right_anchored_rope=True`, `use_seqpack=True`, `transformer_output_only=True` | `xrecsys_two_tower.py:252-351,851-852` |
| user pooling | **`user_query_heads=4`**: 4 query heads do attention pooling with recency decay, `logits = content − gamma*from_newest/QUERY_HEAD_RECENCY_SCALE_TOKENS` (scale=16.0) | `xrecsys_two_tower.py:252-351`; `recsys_two_tower_model.py:2193-2199,71` |
| **tweet tower** | **not a transformer**: `RecsysCandidateTower._project_then_sum` → each token is linearly projected independently, then **summed** → **L2-normalized**. The only input tokens are **the author's double-hash embeddings (2) + 1 SID token**, because production sets `use_post_embedding=False`, `use_user_embedding=False`, `use_post_sid=True`; an assertion requires "at least one of the two is true" | `recsys_two_tower_model.py:224-374,292-364,1897-1922,1924-1936,1945-1947`; `xrecsys_two_tower.py:331-333` |
| similarity | dot product of normalized vectors = cosine, `users @ posts.T`; there is also a MoL scorer (`mol_item_components=1`, `mol_item_adapter_rank=64`, `mol_gate_hidden=32`, `mol_conditioned_gate=True`) | `recsys_two_tower_model.py:2424-2425`; `xrecsys_two_tower.py:316-319` |
| item pools | `max_posts=28_672_000` (home+immersive combined); immersive alone `40_960_000`; candidate tower default `10_240_000` | `xrecsys_two_tower.py:330,396,937` |

**A post's retrieval-side vector = author identity + one semantic ID**: no body-text transformer, no post-id embedding. This explains why, at the retrieval stage, "who posted it + which semantic content cluster" matters more than the wording of the text.

Training objective is sampled softmax / InfoNCE (`recsys_two_tower_model.py:1079-1424`):

| Item | Value | Evidence |
|---|---|---|
| negatives | **in-batch negatives** + **64 global negatives** (`num_global_negatives_per_example=64`, `num_negatives_per_example=0`) | `:1136-1151,1171-1185`; `xrecsys_two_tower.py:252-351` |
| temperature | `warm_scores = raw / temperature`, **`fixed_temperature=0.006`** (fixed, not learned) | `:1243-1244`; `xrecsys_two_tower.py:323` |
| logQ correction | `sampling_weight = 1/tweet_counts`, `logq_correction = log(sampling_weight) * logq_correction_scale`, **scale=2.0** | `:1246-1259,2943` |
| false-negative masking | `mask_in_batch_false_negatives=True` (same-post hash hit → -INF) | `:1293-1303`; `xrecsys_two_tower.py:322` |
| own-negative offset | `true_neg_scores = self_scores + own_negative_logit_offset`, **offset=-2.0** | `:1322-1326`; `xrecsys_two_tower.py:325` |
| user weighting | `positive_count_user_weight_power=0.5` | `:1390-1411` |
| hard / soft negatives | hard: `REPORT, NOT_INTERESTED_IN, SEE_FEWER, UNFOLLOW_AUTHOR, BLOCK_AUTHOR, MUTE_AUTHOR, NOT_RELEVANT`; soft: `CLIENT_TWEET_RECAP_NOT_DWELLED` | `:2984-2994,2996-3000` |
| 3 candidate heads | `head_names=["home","immersive","ld"]`, `num_candidate_heads=3`; weights **`w_fav=1.0` / `w_ld=0.75` / `w_tweet_click=0.0`**; the `home_only` variant keeps only `["home","ld"]` | `xrecsys_two_tower.py:295-296,297,522-536`; `recsys_two_tower_model.py:3054-3056` |
| training | `lr=2e-3`, `emb_learning_rate=0.2`, `empty_history_user_dropout_rate=0.1`, `dense_params_ema_decay=0.99`, H100 `bs_per_device=480, ep=128` | `xrecsys_two_tower.py:272-274,326,430-434` |

**The `tweet_click` head weight is 0.0**: clicks themselves contribute nothing to the retrieval objective.

---

## 7. Where "train toward posts users actually finished reading" lands in code

Three interlocking pieces:

1. **A dedicated long-dwell head**: `ld_positive_actions = [CLIENT_TWEET_RECAP_DWELLED]` (`xrecsys_two_tower.py:294`; `recsys_two_tower_model.py:3036-3038`), with `w_ld=0.75`, second only to fav's 1.0.
2. **The switch**: `ld_label_exclude_clicks` defaults to **False** (`xrecsys_two_tower.py:246`) and is set to **True** in the `xrecsys_two_tower_home_only` config (`:530`) → triggers `_drop_click_only_long_dwell` (`phoenix/xrex/data/recsys/recsys_batch.py:975-976`).
3. **The label-rewrite rule** (`recsys_batch.py:209-227`, the core):

```python
keep = VideoQualityView | QuotedTweetVideoQualityView
     | ((dwell_secs >= 10.0) & any qualifying action present)
actions[..., ClientTweetRecapDwelled] &= keep
```

`dwell_secs = continuous_actions[..., 1]` (i.e. `DWELL_TIME`), `_LD_DWELL_THRESHOLD_SECS = 10.0` (`recsys_batch.py:206`). **qualifying = all actions minus two sets**:

| Exclusion set | Content | Evidence |
|---|---|---|
| `_LD_NON_QUALIFYING_ACTIONS` (18) | `ClientTweetRecapDwelled` / `ClientTweetRecapNotDwelled` themselves + all negative feedback: `ClientTweetReport, ClientTweetNotInterestedIn, ClientTweetSeeFewer, ClientTweetBlockAuthor, ClientTweetMuteAuthor, ClientTweetMuteConversation, ClientTweetNotRelevant, ServerTweetReport, ServerProfileUnfollow, ServerProfileBlock, ServerTweetUnfav, ServerTweetUnreply, ServerTweetUnquote, ServerTweetUnretweet, ClientTweetUnfollowAuthor, ClientTweetUnbookmark` | `recsys_batch.py:179-198` |
| `_LD_CLICK_ACTIONS` (5) | `ClientTweetClick, ClientQuotedTweetClick, ClientTweetPhotoExpand, ClientQuotedTweetPhotoExpand, ServerTweetPostUnexplored` | `recsys_batch.py:199-205` |

**Conclusion: a long dwell manufactured purely by "opening a link / expanding a photo" does not count as "finished reading".** To keep the `RECAP_DWELLED` positive label you need **dwell ≥10 seconds together with a substantive interaction** (fav/reply/quote/retweet/bookmark/share/follow…), **or a video quality view (VQV)**.

This is the hardest code-level evidence for "attention over clicks": **click-only long dwells are removed from the retrieval positives**. Note the scope — the rewrite is gated by `ld_label_exclude_clicks`, and the config that explicitly enables it in the repo is `home_only`.

---

## 8. Thunder: no algorithm inside the following feed

`score_recent` is literally reverse-chronological sort + take (`thunder/thunder_service.rs:339-343`):

```rust
light_posts.sort_unstable_by_key(|post| Reverse(post.created_at));
light_posts.into_iter().take(max_results).collect()
```

Only four algorithm values are accepted, `"" | "recent" | "default" | "latest"`; any other value logs a warning and still goes through `score_recent` (`thunder_service.rs:308`). Capacity and windows (`thunder/config.rs`, all 14 lines):

```
MAX_POSTS_TO_RETURN           = 1200   // :1   per-call return cap
MAX_VIDEOS_TO_RETURN          = 600    // :2
MAX_INPUT_LIST_SIZE           = 10000  // :3   following/exclude list truncation
MAX_REPLY_POSTS_PER_AUTHOR    = 30     // :5
MAX_ORIGINAL_POSTS_PER_AUTHOR = 50     // :6
MAX_VIDEO_POSTS_PER_AUTHOR    = 100    // :7
MAX_TINY_POSTS_PER_USER_SCAN  = 500    // :8   per-author scan depth
MAX_POSTING_LIST_SIZE         = 5000   // :12  per-author per-list capacity
TRIM_FRACTION                 = 5      // :14  shard cleanup
post_retention_seconds        = 172800 // args.rs:48-49 (48 hours); post_store.rs:646-650
qps_limit                     = 8000   // args.rs:90-91, over limit → resource_exhausted (thunder_service.rs:156-161)
```

Key behaviours:

- Over-age posts are filtered at insert time, `p.created_at < now && now - p.created_at <= retention_seconds` (`post_store.rs:132-135`); `is_original = !is_reply && !is_retweet` (`:161`); per list, `while len() >= 5000 { pop_front() }` (`:181-185,190-194,214-218`); cleanup is sharded by `user_id % 5`, evicting when `len() > 5000 || age > retention` (`:501-606,547,554-555`).
- Video eligibility: a retweet can inherit the source post's video (when the source is not a reply), but **replies never enter the video pool** (`post_store.rs:198-210`).
- Fetch path: iterate in reverse order → exclude already-seen → `.take(500)` (`:328`) → drop "retweets of the viewer's own posts" (`:337-339`) → reply eligibility filter (reply to an original post, or reply-to-reply with `in_reply_to_post_id == conversation_id` and the replied-to author followed, `:341-365`) → `.take(max_per_user)` (`:367`).
- Server-side per-author clamp `min(n,50)` / `min(n,30)` (`thunder_service.rs:236-245`); home-mixer passes `per_author_limits: None`, so server defaults apply (`sources/thunder_source.rs:32-41`).
- **3 hardcoded blacklisted accounts**: `1720665183188922368`(@grok), `1909390269533011968`(@gork), `1999031187604717568`(@products) (`thunder_service.rs:32-40`, filtering at `:276-280`).

**Conclusion: the following feed is a 48-hour freshness pool plus per-author quotas; all model scoring happens later, in the Phoenix stage.** "Followed, therefore guaranteed to be seen" does not hold — Thunder only guarantees a chance to enter the candidate set.

---

## 9. SimClusters: community-cluster retrieval

### 9.1 Scale, generation and sparsity

Model version **`Model20M145K2020 = "20M_145K_2020"`** → 20M users / **145K clusters** (`simclusters/simclusters_v2/common/ModelVersions.scala:9`). The KnownFor job **rebuilds weekly** (`batchIncrement = Days(7)`, `firstTime=2020-10-04`); its input is an **approximate cosine similarity graph built from the follow relationship**, `FollowingsCosineSimilaritiesManhattanSource(".../approximate_cosine_similarity_follow")`, with `minActiveFollowers=400`, `topK=20000000`, `maxNeighbors=400`, `maxEpochs=3`, `wtCoeff=10.0`, a `squareWeightsEnable` switch, and a **warm start from the previous snapshot** (`scalding/update_known_for/UpdateKnownFor20M145K2020.scala:37,39,43-44,57,58,60,62,64,65,67-76,81`). **The actual clustering solver `UpdateKnownForSBFRunner` belongs to the external WTF package and is not in this repo** (`:78-92`).

The representation is parallel sparse arrays `clusterIds` (descending by score) + `sortedClusterIds/sortedScores` (sorted by id for merge-joins) (`common/SimClustersEmbedding.scala:14-17`); `cosineSimilarity` is the dot product of two L2-normalized arrays (`:144-150`). Explicit K values (`simclusters_v2/summingbird/common/Configs.scala`):

```
topKTweetsPerCluster   = 1600   // :51  each cluster's inverted list keeps 1600 posts
topKClustersPerEntity  = 50     // :53  each entity (user/author) keeps 50 clusters
topKClustersPerTweet   = 400    // :55  each post keeps 400 clusters
scoreThresholdForEntityTopKClustersCache  = 0.02   // :57
scoreThresholdForTweetTopKClustersCache   = 0.02   // :59
scoreThresholdForClusterTopKTweetsCache   = 0.001  // :61
scoreThresholdForClusterTopKEntitiesCache = 0.001  // :63
HalfLife = 8.hours              // :39  exponential score-decay half-life
MinFavoriteCount = 8            // :65
OldestTweetInLightIndexInMillis      = 1.hours  // :67
OldestTweetFavEventTimeInMillis      = 3.days   // :69
OldestVideoTweetFavEventTimeInMillis = 7.days   // :73
```

Truncation implementation: `computeTweetTopKClusters` first maps `score < 0.02 → None`, then `.sortedReverseTake(400)`; `computeClusterTopKTweets` first maps `score < 0.001 → None`, then `.sortedReverseTake(1600)` (`scalding/offline_job/SimClustersOfflineJob.scala:113-165`). **Sparsity: a post attaches to at most 400 clusters (0.28% of 145K); a cluster's inverted list holds at most 1600 posts.**

### 9.2 Pool-admission gates (the part that matters most for small accounts)

- **A post needs `favoriteCount >= 8` to enter the persistent index** (`summingbird/storm/PersistentTweetJob.scala:23,50-57`).
- A producer (author) embedding needs `faverCount > minNumFaversForProducer = 100` (`scalding/embedding/ProducerEmbeddingsFromInterestedIn.scala:474`; the relaxed variant uses `minNumFavers=15`, `AggregatableLogFavBasedProducerEmbeddings.scala:137`); the producer side has its own sparsity settings `numClustersPerNoun=60`, `numNounsPerClusters=500`, `thresholdForEmbeddingScores=0.01` (`AggregatableProducerEmbeddings.scala:27-31`).
- User-interest threshold `favScoreThresholdForUserInterest = 0.3` (2020 version; updated 1.0, dec11 0.15) (`Configs.scala:27-32`); post embedding type `EmbeddingType.LogFavBasedTweet` with `usingLogFavScore=true`, video version `LogFavBasedVideoTweet` (`SimClustersProfile.scala:142-150,152-160`).

**Implication: SimClusters is not a new-account channel.** 8 favs to enter the persistent index, and an author needs 100 favers to have a producer embedding at all.

### 9.3 Online ANN

Client constants (`home-mixer/sources/simclusters_source.rs`): `MAX_SANN_CANDIDATES=10_000`, `MAX_RESULTS=800`, `SOURCE_EMBEDDING_TYPE=LOG_FAV_LONGEST_L2_EMBEDDING_TWEET`, `CANDIDATE_EMBEDDING_TYPE=LOG_FAV_BASED_TWEET`, `MODEL_VERSION=MODEL_20M_145K_2020`, `ANN_MAX_NUM_RESULTS=200`, `ANN_MIN_SCORE=0.0`, `ANN_MAX_TOP_POSTS_PER_CLUSTER=800`, `ANN_MAX_SCAN_CLUSTERS=50`, `POST_ANN_MIN_SCORE=0.5`, `MAX_SEED_AGE=90 days`.

Flow: seeds = explicit + implicit engagement signals sorted by `Reverse(engaged_at_ms)` and deduplicated (`:288-312`, age ≤90 days `:226`) → `max_per_query = max(10000/seed count, 1)` (`:233`) → ANN with `ScoringAlgorithm::COSINE_SIMILARITY` (`:329`) → filter `score > 0.5` (`:245`) → `interleave_by_post_id` round-robin merge → `.truncate(800)` (`:251-252`). Local moka cache holds 2_000_000 entries with TTL 600s (`:56-59`).

Server side (`simclustersann/candidate_source/`): `sourceEmbedding.truncate(50).getClusterIds.toSet` → `clusterTweetCandidatesStore.multiGet` → approximate cosine (`SimClustersANNCandidateSource.scala:63-96`); per cluster `.take(maxTopTweetsPerCluster)` (`ApproximateCosineSimilarity.scala:77`), exclude the seed itself (`:80`), accumulate `score * sourceClusterScore` (`:84`) and `score²` (`:86`), finally `.filter(_._2 >= minScore).sortBy(-_._2).take(min(maxNumResults, 1000))` (`:128-131`, with `MaxNumResultsUpperBound=1000` at `:32`).

**Online scans only the first 800 posts per cluster while the offline index stores 1600** — the second half is never reachable online. The ANN server-side cluster configuration values are resolved by the external `relevance_platform` package and are **not public** (`ClusterConfigModule.scala`).

---

## 10. DPP: it does not change scores, it only decides who survives

Kernel (`vm-ranker/dpp.rs:103-152`):

```
max_score = inputs[top_indices[0]].score.max(1e-6)
theta     = config.theta.clamp(0.0, 1.0 - 1e-6)
alpha     = theta / (2.0 * (1.0 - theta))          # :105-106
q_i       = score_i / max_score                    # seed is pinned at q=1.0, :129-138
qf_i      = exp(alpha * q_i)
L_ii      = qf_i²                                  # :144
cos_ij    = dot(e_i,e_j)/(‖e_i‖‖e_j‖)              # :147-151
L_ij      = qf_i * qf_j * cos_ij                   # :152
```

A standard quality×similarity kernel, **`L = Diag(q)·S·Diag(q)` with `q_i = exp(alpha · score_i/max_score)`**.

| Parameter | Production value | Source file |
|---|---|---|
| `DppEnabled` / `TopicDppEnabled` | true / false | `vm-ranker/params.rs:265-270,271-276` |
| **`DppTheta`** | **0.65** → **alpha ≈ 0.9286** | `vm-ranker/params.rs:277` |
| **`DppMaxSelectedRank`** | **150** (DPP runs only on the top 150 by score) | `vm-ranker/params.rs:278-283` |
| `DppGreedyOrder` / **`DppWindow`** | false / **0 (sliding-window mode off)** | `vm-ranker/params.rs:284-289,290` |
| CLI defaults (overridden by feature switches) | `dpp_theta=0.5`, `dpp_top_k=50`, `embedding_dim=1024` | `vm-ranker/args.rs:18-19,21-22,27-28`; override site `scoring/mod.rs:59-71` |

As θ→1, alpha→∞ (pure score); as θ→0, alpha→0 (pure diversity). Greedy log-det maximization: the first pick is the largest diagonal entry (or the pinned seed), `log_det = ln(first_val)` (`dpp.rs:300`), incremental Cholesky `cv = L_ii − Σ_j cholesky[j][i]²` (`:323-327`), stop when `best_vol <= 1e-6` and record `rank_exhausted` (`:334-338`; whole routine `:269-360`). The alternative sliding-window mode (when `DppWindow>0`, `:362-414`): `weights[d]=0.5^(d/half_distance)` (`:373`), `penalty=min(cos²+(same L1 SID ? sid_lambda : 0), 1.0)` (`:383`), `gain_i = quality_i × Π(1 − w_d·penalty)` (`:403`), with quality using `exp(2α·score/max_score)` (`:112`). **Production window=0, so this path is inactive.**

### 10.1 "DPP trades score for diversity" is the wrong framing

`serve` (`dpp.rs:187-261`) **does not modify any score**: the selected ids are re-sorted by their **original scores** and then zipped back onto the sorted scores (`:195-215`), and the metric is hardcoded to **`DPP_RESCALING = "unchanged"`** (`:244-246`). Unselected candidates get **score = 0.0** inside `rank_with_memo` (`scoring/dpp_model.rs:265-268`).

**DPP is a selector/filter: the cost shows up in "which posts survive", not in "how many points each post loses".** The instrumentation is `DPP_AVG_SIMILARITY before/after` (`:232-242`) and `DPP_TOP_K_OVERLAP` (`:248-258`); **no measured online values are public**. Unit tests confirm: identical embeddings → only the highest-scoring one survives (`dpp.rs:502-521`); orthogonal vectors get promoted (`:524-546`); `filter_only_preserves_original_scores` (`:549-581`); a seed suppresses near-duplicates without consuming a top_k slot (`:609-659`).

| Behaviour | Implementation | Evidence (`vm-ranker/scoring/dpp_model.rs`) |
|---|---|---|
| missing embedding | `random_unit_embedding(1024)` + `embedding_missing=true`, norm recorded as 1.0 → **neither penalizes others nor is penalized by them** | `:26-54` |
| **retweets share the source post's embedding** | `embedding_id = retweeted_tweet_id if != 0 else tweet_id` → multiple retweets of the same content are fully similar, so **only one survives** | `:83-87` |
| **cross-request diversity window** | `HISTORY_MAX_AGE_MS = 10*60*1000` → only content served in the **last 10 minutes** is considered, paginated by `served_time_ms`, reversed within a page | `:14,132-157` |
| seed and L1 | `seed_tweet_id` (score 0.0, pinned) suppresses posts near-duplicating the last served item; `l1 = semantic_ids.first()` is used only for the sliding-window SID penalty, and is fetched only when `sid_lambda > 0` | `:106-130,100`; `scoring/mod.rs:76-84` |

**The real multiplicative deductions are not in DPP**: author-diversity decay `(1−floor)·decay^k + floor` and the OON discount live in `xai-value-model/scoring.rs:304-306,308-325,327-336`, with parameters in `vm-ranker/params.rs:199-216,241-246`. **Values and operational implications are in `02-scoring-ranking.md`; this document does not duplicate them.** In ordering they come before DPP — the `score` DPP sees is already discounted.

---

## 11. Index admission: why a post never enters the retrieval pool

The most practically useful section for "my post gets zero impressions". Admission happens in `phoenix-rankall-strato`, **before anything online**.

### 11.1 Triggers and rate limiting

A fav event → `nextPowerOfTwo(count)` threshold gate → emits `PhoenixRankAllIndexingRequest{postId, eventSource=Fav}` to `favIndexingEventKafkaTopic` (`columns/favoriteEventProcessor.strato:14-21`, cached path `:120-134`, uncached `:135-148`). **Unfavorite events are ignored outright** (`:155-157`). The file describes itself as "rate-limited per tweet by power-of-two favorite-count thresholds" (`:173-177`). The threshold cache is `MemcacheColumn ttl = 50.hours` (`tweetUpdateThresholdsCache.strato:19`). A second entry point: `columns/phoenix_rank_all/postCreationEventProcessor.strato:7-15` consumes ContentUnderstandingMetadataV2 events → `eventSource=PostCreation`.

The gate (`lib/eventProcessing.strato:42-60`): `!engagementsAgedOut && !tweetAgedOut && passedThreshold && belowMaxEngagements && !updatedRecently`, with constants `maxTimeSinceFirstUpdate=48.hours` (`:28`), **`minTimeSinceLatestUpdate=1.minute` (debounce)** (`:30`), **`maxTweetAge=49.hours`** (`:32`), `maxEngagements=1073741824` (2^30, `:34`), **`minEngagements=32`** (`:36`).

**Implication: the fav count must cross a power-of-two step (1→2→4→8→16→32…) to trigger re-indexing, the same post is updated at most once per minute, and indexing stops entirely 49 hours after posting.** A post is re-evaluated a finite number of times in its lifetime.

### 11.2 The admission decision tree

`columns/phoenix_rank_all/phoenixRankAllCandidateProcessor.strato:538-596`:

```scala
isCommunityPost / isRepost                                             // :538-539
if (eventSource == Fav && !isCommunityPost && !isRepost)
  buildSearchUnfilteredIndex(...)                                      // :541-542 requires favCount>=1
isReply / isAdultPost = isNsfwPost(unifiedPostAnnotations)             // :545-546
shouldDropPostByVF = eventProcessing.shouldDropPostByVF(postId)        // :547  ← VF checked first
shouldDropPost = shouldDropPostByVF || isAdultPost                     // :548
if (isCommunityPost)  numSkippedCommunity                              // :549-550
else if (isReply) { isSelfReply → skip; shouldDropPost → numSkippedFilteredReplies;
                    else 1FavReplyIndex + 32FavReplyIndex + Metadata }  // :551-561 (only when eventSource==Fav)
else if (isRepost)    numSkippedReposts                                // :564-565
else if (shouldDropPost) { hasImmersiveVideo && Fav && isAdultPost
                             → NsfwVideoIndex + Metadata + MMEmbMetadata // :567-570
                           else numSkippedPosts }                      // :572
else Fav → 1FavIndex/1FavIndexBackup/1FavTopicIndex/32FavIndex
           (+video/1fav_video/imagine/ai_video_* if a qualifying video exists) + Metadata // :576-589
     PostCreation → PostCreationIndex(+video/ai_video) + Metadata       // :590-596
```

**The 6 categories that never enter the main retrieval indices**:

| # | Category | Test | Evidence |
|---|---|---|---|
| 1 | **community posts** | `communities.nonEmpty` → skipped in every index | `eventProcessing.strato:256-258`; processor `:549-550` |
| 2 | **retweets** | `coreData.share.nonEmpty` → skipped in every index (can only be indexed as the source post) | `eventProcessing.strato:175-180`; processor `:564-565` |
| 3 | **self-replies** | `reply.inReplyToUser == core.user` → skipped | `eventProcessing.strato:242-246`; processor `:554-555` |
| 4 | **VF says drop** | see §11.4 | processor `:547-548,572` |
| 5 | **NSFW posts** | `tweetBoolMetadata.isNsfw` → skipped from the main indices; **the only exception**: NSFW + qualifying immersive video + Fav event → enters the separate `nsfw_video` index only | `eventProcessing.strato:332-340`; processor `:567-570` |
| 6 | **replies** | enter only the dedicated `1fav_reply` / `32fav_reply` indices, not the main `1fav`/`32fav`; and they are **built only when `eventSource == Fav`** | processor `:551-561` |

### 11.3 Per-index gates and retention windows

| Index | Gate | Evidence |
|---|---|---|
| `search_unfiltered` / `1fav` | `favoriteCount >= 1` / unconditional (favCount 0 only increments a race counter) | processor `:46-60,78-89` |
| **`32fav`** | **`favoriteCount >= 32`** | processor `:62-76` |
| video indices (`video`/`1fav_video`/`imagine`/`ai_video_*`) | `hasValidImmersiveVideo` = **all media types ∈ {TweetVideo, AmplifyVideo} and duration > 10s** | processor `:263-275,311-323,397-411`; `eventProcessing.strato:23-24,403-418` |
| author eligibility | **`nsfwUser == false && nsfwAdmin == false`** | `eventProcessing.strato:157-161` |
| topic / AI video | 6 experiment branches `1fav_topic`, `1fav_topic_option_1..5`; author-topic matching uses the last 15 posts with thresholds 0.90/0.75/0.50; AI video splits into `ai_video_self` (UserDeclared) and `ai_video_detected` (C2paClient/GrokSignature/AgentApplied) | processor `:116-165,213-261,356-369`; `eventProcessing.strato:475-479` |

Retention windows (`phoenix-rankall/src/config/mod.rs:168-234`, in hours):

| pipeline | Windows |
|---|---|
| **Main** | post_creation 24; 1fav 24 & 48; 1fav_video 48 / bounded(48→96) / bounded(96→336) / bounded(96→720); 32fav 24; 1fav_reply 24; 32fav_reply 24; video 48/96/168/336/720; nsfw_video 48/168; **evergreen_video and evergreen_nsfw_video each `24*365*5` (5 years)** |
| Topic / Metadata | 1fav 24 + 6 topic branches at 24 each / 24, 48, 72 |
| Sid | 1fav 24, 1fav_reply 24, 1fav_video 48+bounded, video 6 / bounded(6→48) / 48 / 96 / 336, nsfw_video 48/168/336, evergreen_video 5y, imagine 96, ai_video_self and ai_video_detected each 24/48/168 with `.excluding_posts_in("nsfw_video")` |
| SidTail | tail 24 |

Kafka routing: Main|Sid → `phoenix_rank_all_indexing_event`; Topic → `..._backup`; Metadata|SidTail → `phoenix_rankall_metadata_event`; Analysis → `home_mixer_phoenix_scored_candidates` (`config/mod.rs:147-155`). Other constants: `seek_hours=12` (`:43-44`), `dump_interval_secs=180` (`:55-56`), `versions_to_keep=3` (`:58-59`), `score_prefix="phoenix.HomeExperiment1Lap7."` (`:64-69`), `sid_min_post_age_seconds=180.0` (`:83-84`), `sid_backfill_qps_cap=800_000` (`:92-93`), **`tail_max_author_followers=1000`** (`:104-105`), `tail_min_fav_count=0` (`:107-108`). A second blacklist layer uses `blacklisted_post_ids.txt` / `blacklisted_author_ids.txt`, with `is_blocked = post_id ∈ set || author_id ∈ set` (`src/processor/blacklist.rs:14-15,32-34`); records with `post_id==0 || author_id==0 || index_name.is_empty()` are dropped outright (`src/processor/main_processor.rs:52-55`).

**`tail_max_author_followers = 1000`: the tail index only accepts authors with ≤1000 followers.** This is one of the few admission parameters in the repo that explicitly routes by author size — small accounts do have a dedicated tail channel, but it is still bound by the 24-hour window and every gate above.

### 11.4 The index-time VF call: no viewer context

`lib/eventProcessing.strato:260-279`: if decider `enable_vf_rust_should_drop_tweet` is true → `#<visibility/xai/shouldDropTweet>.fetch(postId, {safetyLevel = TimelineHomeRecommendations})` (`:268-269`); otherwise → `#Tweet<visibility/service/shouldDropTweetV2>.fetch(postId, {safetyLevel = TimelineHomeRecommendations, forUserId = None})` (`:275-276`). **Both paths default to false (pass) on error.**

What can be established: **the call carries only postId + safetyLevel**; **the legacy path explicitly passes `forUserId = None`**; **it fails open**. What cannot: how viewer-relative conditions such as `ViewerFollowsAuthor` / `ViewerBlocksAuthor` / age / settings resolve with no viewer, and therefore **which audience-gated rules actually fire at index time cannot be determined from this repo** — do not assert that a given audience rule definitely applies at index time. The rule list itself is in `visibility-filtering/rules/levels.rs:338-381`.

---

## 12. The viewer behaviour sequence

Two hydrators use the same UAS client with different parameters:

| | scoring (ranking) | retrieval |
|---|---|---|
| length cap | `MaxSeqLengthScoring = 1024` | `MaxSeqLengthRetrieval = 1024` |
| aggregation type | **`DENSE_WITH_LONG_DWELL_HOME_EXCURSION`** | **`DENSE_WITH_LONG_DWELL`** |
| model type | `UaasModelType::Ranking` | `UaasModelType::Retrieval` |
| window / format | `UAS_WINDOW_TIME_MS = 300_000` (5 minutes) / `ResponseFormat::Arrow` | same |

Evidence: `home-mixer/params/param.rs:1130-1140` (both 1024s), `:175-186` (both aggregation types), `params/config.rs:39` (300_000); `query_hydrators/scoring_sequence_query_hydrator.rs:92-118` (`:106` window, `:107` max_len, `:110` Arrow, `:113` Ranking); `query_hydrators/retrieval_sequence_query_hydrator.rs:49,51,58`; the client signature's 3rd parameter is `window_time_ms: u32` and 4th is `max_sequence_length: u32` (`clients/user_action_aggregation_client.rs:61-73`, request body `:239-251`, `client_id="xai-home-mixer"`).

Enum values: `DENSE=2`, **`DENSE_WITH_LONG_DWELL=15`**, **`DENSE_WITH_LONG_DWELL_HOME_EXCURSION=30`**, `DENSE_WITH_LONG_DWELL_FAIR_VIEW=32`, `DENSE_WITH_RECENT_IMPRESSIONS=34` (`phoenix/python/common/xai-proto/proto/recsys.proto:2003-2039`, mirrored on the serving side at `phoenix/crates/serving/xai-recsys-proto/proto/recsys.proto:2003-2039`). Both sides fall back to `DenseWithFavVqvCleaned` (`scoring_sequence_query_hydrator.rs:47`). The action types are exactly the 60 discrete + 8 continuous heads of §4; the history side additionally consumes non-head actions with enum values 60+.

**Time decay is not in the hydrator, it is in the model**, in four places:

| Mechanism | Parameters | Evidence |
|---|---|---|
| log-dt Fourier encoding | `RECENCY_LOG_DT_SCALE=15.0`, `RECENCY_FOURIER=8`, applied to `RECENCY_ACTIONS` | `recsys_model.py:184-189` |
| `time_gap` exponential bucketing | `TIME_GAP_CARDINALITY=19`, boundaries `60*2^k` seconds (k=0..16, 1 minute → ~18 hours), `lr_scale=4.0` with zero_init | `recsys_feature_prep.py:51-52,73-78,1056-1069` |
| two-tower query-head recency penalty | `logits = content − gamma*from_newest/QUERY_HEAD_RECENCY_SCALE_TOKENS` | `recsys_two_tower_model.py:2193-2199` |
| hard windows | `recent_positive_window_secs=900` (15 minutes), `recent_positive_last_n=5`, `recent_positive_last_n_cap_secs=7200` | `recsys_model.py:1415-1417`; mask construction `:370-401` |

History statistics window `STATS_HISTORY_WINDOW_DAYS=28`, `MS_PER_DAY=86_400_000`, `engaged_history_topics(sequence, request_time_ms − days*MS_PER_DAY)` (`scoring_sequence_query_hydrator.rs:21-22,60`).

**Honest boundary**: `UAS_WINDOW_TIME_MS=300_000` is the `window_time_ms` passed to UAS. The sequence itself covers 1024 history events, so it is **not "only take the last 5 minutes of behaviour"**; but **the exact semantics of that field on the UAS server side are not in this repo and cannot be confirmed further** (only the client signature `user_action_aggregation_client.rs:61-73` is available).

---

## 13. Hash-based vocab-free embeddings (infrastructure, not a reach policy)

Core implementation (`phoenix/xrex/models/recsys_embedding.py:154-172`, numba njit):

```python
raw      = (id * scales[j] + biases[j]) % modulus
out[i,j] = 0 if id == 0 else ((raw % (num_buckets - 1)) + 1)
```

**Two hash functions per entity** (the scales lists for all four entities have 2 elements, `recsys_embedding.py:212-226`), **bucket 0 is reserved for padding**, valid buckets are `1 .. num_buckets-1`, and `id == 0` maps straight to 0. This is classic double hashing / Bloom embedding: trade collisions for a vocabulary, and never maintain an id→row mapping. Production bucket counts are **user 100_000_000 / item 100_000_000 / author 30_000_000 / ip 10_000_000** (`xrecsys.py:586-589`), hash constants at `xrecsys.py:174-185`; the `HashKeys` dataclass defaults are only nano scale (user/item 100_000, author 10_000, ip 0, `recsys_embedding.py:177-196`) and production values are injected by `_make_cfg`.

**One shared large table + segment offsets** (`recsys_embedding.py:234-248`): `offset_user = 1 + 64 = 65` (1 PAD + 64 action tokens), `offset_item = 65 + 100M`, `offset_author = 65 + 200M`, `offset_ip = 65 + 230M`; `input_vocab_size = round_up(240_000_061, INPUT_VOCAB_K=512) = 240_000_512` (`xrecsys.py:146-155,48-51`). Each row is `emb_table_width=1024` wide, projected up to `emb_size=2560`. SID level 7 also uses hashing rather than a lookup table: `mixed = h*1540483477; mixed ^= mixed>>16; code = abs(mixed)%256 + 1` (`recsys_feature_prep.py:817-819`), likewise avoiding 0.

---

## 14. Explicitly not in the repo

| # | Missing item | Known boundary |
|---|---|---|
| 1 | The **actual clustering solver** for SimClusters 145K | `UpdateKnownForSBFRunner` belongs to the external WTF package (`UpdateKnownFor20M145K2020.scala:78-92`). Louvain inside the repo is used only for secondary topic clustering, and its `cosine_similarity_threshold` / `resolution_factor` are required CLI parameters with **no hardcoded values** (`scalding/embedding/twice/InterestedInTwice.scala:141-143`) |
| 2 | SimClusters ANN **server-side cluster configuration values** | `ClusterConfigModule.scala` resolves them per service name through the external `relevance_platform` package; the only online numbers available are the home-mixer client constants (§9.3) |
| 3 | **The semantics of `window_time_ms=300_000` on the UAS server** | The UAS implementation is not in the repo, only the client signature (`user_action_aggregation_client.rs:61-73`) |
| 4 | The Phoenix scoring service's **batching/sharding strategy** | `PhoenixScorer` puts all ≤2800 candidates into a single `candidate_sets[0]` in one shot (`phoenix_scorer.rs:102-114`; `util/phoenix_request.rs:309`), **no chunking logic on the Rust side**; `candidate_seq_len=64` + `seqpack_candidate_count=[128]` hints that the server packs by 64/128, but the scheduling code is unconfirmed |
| 5 | **The value of `TOP_LOG_PROBS_NUM`** | Defined in the external crate `xai_candidate_pipeline::...::phoenix_prediction_client`; this repo only imports it (`util/phoenix_request.rs:9,222`) |
| 6 | **Measured online values** for how much score DPP "sacrifices" | Only `DPP_TOP_K_OVERLAP` and `DPP_AVG_SIMILARITY before/after` are instrumented (`dpp.rs:232-258`); scores are not modified, so "sacrificing score" does not hold at the code level |
| 7 | **The label meaning of the two bits in `safety_filter_bits=0b11`** | `safetyLabelMaskSeq` is just an int64 column (`data/recsys/feature_config.py:164-208`); and production `safety_filter_mode="off"`, so the path is inactive |
| 8 | Index-time VF's **audience resolution behaviour** | See §11.4: how viewer-relative conditions are decided under `forUserId = None` cannot be determined from this repo |