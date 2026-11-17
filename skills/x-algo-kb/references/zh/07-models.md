# 07 · 召回与排序模型：Phoenix、双塔、DPP 与索引准入

> 证据基准：`phoenix/xrex/*`、`home-mixer/*`、`thunder/*`、`simclusters/*`、`vm-ranker/*`、`phoenix-rankall*/*`，commit `a284320b66a9dce35e6f5d6b052ee308eeb12326`。
> 分工：**权重数值一律见 `02-scoring-ranking.md`**（`vm-ranker/params.rs` 无 sync 戳、默认值过期，本文不复制权重表）；过滤链逐条语义见 `03-retrieval-filtering.md`。本文只讲模型结构、训练目标与索引准入。
> 标注约定：**生产默认** = 配置当前值；**代码在但默认关** = 路径存在、开关 off 或权重 0；**不公开** = 仓库里查不到。

---

## 1. 端到端漏斗（真实数字）

管线在 `home-mixer/candidate_pipeline/phoenix_candidate_pipeline.rs`，顺序 query_hydrators → sources → hydrators → filters → scorers → selector → post_selection_hydrators → post_selection_filters。

| 阶段 | 内容 | 证据 |
|---|---|---|
| sources（9 个，按此顺序） | thunder, popular_posts, tweet_mixer, simclusters, phoenix, phoenix_topics, phoenix_moe, sid, cached_posts | `phoenix_candidate_pipeline.rs:385-395` |
| filters（**21 个**，打分前） | DropDuplicates → ZeroFavCodivert → CoreDataHydration → NewUserSoftNsfw → Age(48h) → SelfTweet → OONRetweetReply → OONNsfwSimclusters → RetweetDedup → IneligibleSubscription → PreviouslySeen×2 → PreviouslyServed → ViewerMutedKeyword → AuthorSocialgraph → Video → TopicIds → NewUserMinEngagement → InventoryHoldout → FavHoldout → **FairShareRanking** | `phoenix_candidate_pipeline.rs:432-456` |
| **打分预算 2800** | `FairShareRankingFilter` 按 `served_type` 比例分配 `PhoenixScoresResultSize=2800`（最大余额法）；客户端再 `.take(2800)` 兜底 | `filters/fair_share_ranking_filter.rs:29-32,59-101`；`params/param.rs:1509-1520`；`util/phoenix_request.rs:20,204` |
| scorers | PhoenixScorer → ImmersiveVideoScorer → **VMRanker** → PageDecodeRerank → PageRlExploration | `phoenix_candidate_pipeline.rs:481-487` |
| selector | `TopKScoreSelector`：按 `candidate.score` 降序取 **50** | `selectors/top_k_score_selector.rs:15-17,32-38`；`params/config.rs:19` |
| post_selection_filters（5 个） | **VFFilter** → AncillaryVFFilter → AncestorVideoFilter → DedupConversationFilter → VideoCarouselFilter | `phoenix_candidate_pipeline.rs:515-521` |
| 最终条数 | `RESULT_SIZE = 35`；For You 外层 `FOR_YOU_MAX_RESULT_SIZE = 35 + 5 + 8 = 48` | `phoenix_candidate_pipeline.rs:1153-1155`；`params/config.rs:20-24` |

两个容易读错的点：

1. **可见性过滤（VF）出现两次**：一次在**离线索引准入**（`phoenix-rankall-strato`，决定能不能进召回池，§11），一次在**在线 top-50 之后**（`VFFilter`，决定能不能真的展示）。两处 safety level 都是 `TimelineHomeRecommendations`，但上下文完全不同。
2. **`VFFilter` 不扣分**：`Drop(_) | Tombstone | NotEvaluated` 丢弃，`Allow | Interstitial | Avoid | Downrank` 保留（`home-mixer/filters/vf_filter.rs:22-27`）。**Downrank 在这一步只是放行**，降权发生在别处。

---

## 2. Phoenix 是 pointwise，不是 listwise：候选隔离 mask

本文最重要的一条架构事实。`phoenix/xrex/pallas/ranker_attention_utils.py:54-56`：

```python
history_mask        = kv_is_history & (q_is_history | q_is_candidate)
candidate_self_mask = q_is_candidate & kv_is_candidate & (q_pos == kv_pos)
return history_mask | candidate_self_mask
```

`q_pos == kv_pos` **彻底切断候选之间的注意力**：每个候选只能看 user prefix + history + **自己**。边界 `history_upper = num_user_prefix_tokens + history_seq_len`（`phoenix/xrex/models/recsys_attention.py:39-42,110-113`）；CuTeDSL FA4 kernel 对应 `fwd_diag_cnt = is_cand`、`fwd_diag_idx = t`（`phoenix/xrex/cutedsl/ranker_attention_fa4.py:79-80`，block=128）。RoPE 上**所有候选共享同一位置 `history_end`**（`phoenix/xrex/models/recsys_model.py:277-298`），候选之间无位置偏序。

**结论：Phoenix 对每条帖子独立打分——「这条帖子 vs 你的历史」，候选之间互不可见。** 所以：

- 模型**不会**因为「这一屏已有 3 条同作者帖」而压低第 4 条；
- slate / 多样性效应全部来自模型之外：DPP（§10）、作者多样性衰减与 OON 折扣（`xai-value-model/scoring.rs`，数值见 `02-scoring-ranking.md`）；
- slate 上下文只是**回传字段**：`served_slate_context` 从预测结果取出挂到候选上（`home-mixer/scorers/phoenix_scorer.rs:145-147`），不是打分输入。

---

## 3. 生产架构与超参（配置名 `home_direct_packed`）

base `phoenix/xrex/configs/xrecsys.py:318-386`，生产 override `:545-590`，attention/FFN 装配 `:1046-1084`。

| 项 | 生产值 | 证据 |
|---|---|---|
| 序列布局 | `history_seq_len=1022` + `num_user_prefix_tokens=2`（`enable_user_embedding + has_user_features`）= user 段 **1024**（强制 2 的幂）；`candidate_seq_len=64`；serving 总长 **1088** | `xrecsys.py:318-386,797-801,58-70,256-262` |
| 主干 | `num_layers=8`、`emb_size=2560`、`emb_table_width=1024`（表宽 1024 投影到 2560） | `xrecsys.py:318-386` |
| 注意力 | `query_heads=20` / `kv_heads=4`（**GQA 5:1**）/ `key_size=128`；**`causal=False`**；`rotary=True` + **`right_anchored_rope=True`**；**`qk_norm=True`**；`attn_logit_cap=-1`（关闭，框架默认 80.0 + `soft_sign`） | `xrecsys.py:318-386,1046-1084` |
| FFN | `widening_factor=2`、`gated_mlp=False` | `xrecsys.py:1046-1084` |
| candidate-only 层 | **2 层**，`candidate_only_attn_impl="cutedsl_ranker_candidate_only_attn"` | `xrecsys.py:545-590` |
| seqpack | `use_seqpack=True`、`BetaLengthDistribution(min_len=126, max_len=1022, mean_len=510→生产 414, alpha=1.0, beta=1.0, block_size=128)`、`seqpack_candidate_count=[128]` | `xrecsys.py:378-385,551-553,545-590` |
| H100 训练 | `bs_per_device=1024`、`num_microbatch=8`、`ep=64`、`lr=7.1e-4`、Muon(`b1=0.95, b2=0.98, consistent_rms=0.2, matrix_weight_decay=0.014, split_fused="qkv:128"`)、embedding row-wise Adagrad(`lr=0.28, half_life_steps=2500`)、`fp8_gemms=ALL`、`clip_by_global_norm=1.4` | `xrecsys.py:389-418,545-590` |

**训练序列比 serving 长**：`_sequence_len` 还乘负样本块 `(1 + num_negatives_per_example)`（`xrecsys.py:256-262`），ranking dataset 该值默认 **1**（`phoenix/xrex/data/parquet_recsys.py:1943`）且 `home_direct_packed` 未覆盖。1088 是**推理布局**。

本地冒烟版 `home_direct_packed_nano`：`emb_size=512, num_layers=4, query_heads=4, kv_heads=2, emb_table_width=128`（`xrecsys.py:619-642`），配 `--history_seq_len 128 --candidate_seq_len 16`、`sequence_len=146` 起服务（`phoenix/QUICKSTART.md:128-151`）。**只用于本地跑通，不是生产规模。**

---

## 4. 预测头：60 个离散 action + 8 个连续值

`output_vocab_size = round_up(ACTION_TYPE_MAP_LEN=60, OUTPUT_VOCAB_K=64) = 64`（`xrecsys.py:48-51,156-158`）。**head index 就是 `ActionName` 的 enum 值：0..59 有效，60..63 是 padding。** enum 60 及以上（`CLIENT_TWEET_EXTERNAL_LINK_LONG_DWELLED=60` … `CLIENT_TWEET_SWIPE_TO_PROFILE=115`，ADS 段 128-213+）**只作为历史输入 action，不是预测目标**。

完整 60 头（`phoenix/python/common/xai-proto/proto/recsys.proto:519-579`）：

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

8 个连续头（`recsys.proto:764-773`；`num_continuous_actions=8`、`continuous_action_hidden_dim=64`，`recsys_model.py:1388`）：`HOME_PROFILE_VISIT_SECS=0`、`DWELL_TIME=1`、`CLICK_DWELL_TIME=2`、`HOME_VIDEO_CONTINUATION_SECS=3`、`BRIDGE_PROBABILITY=4`、`ADS_WEB_CT_PURCHASE_VALUE=5`、`ADS_VIDEO_WATCH_TIME_SECS=6`、`ADS_VIDEO_LENGTH_SECS=7`。

解码：离散 `logits = out_embeddings @ unembeddings`（`recsys_model.py:3487-3490`）；连续走 `continuous_unembeddings`（`:3493-3509,3684-3775`）。**这就是「多动作预测」的具体含义**：一次前向为每条候选输出 60 个动作概率 + 8 个连续值，加权求和成最终分的部分在 value model（`02-scoring-ranking.md`）。

---

## 5. Loss：离散 BCE + CREAD 停留时长

总 loss = Σ 离散 multihot + Σ 连续 + 激活 L2（`act_l2_weight=5e-7`，`xrecsys.py:882`；汇总 `recsys_model.py:5501-5506`）。

### 5.1 离散头

`phoenix/xrex/models/loss_recsys.py:21-55`：逐 action `optax.sigmoid_binary_cross_entropy`，乘 `padding_mask * loss_mask`，再除以 `sum(mask*weights)`。

| 机制 | 生产值 | 证据 |
|---|---|---|
| `view_loss_weight` | **0.5**，作用于 `VIEW_LOSS_ACTION_INDICES = {RECAP_DWELLED, RECAP_NOT_DWELLED, VIDEO_QUALITY_VIEW}` | `xrecsys.py:545-590`；`data/recsys/constants.py:566-570`；`recsys_model.py:5294-5300` |
| 条件头权重 | `home_video_continuation_loss_weight=0.013`、`home_profile_visit_secs_loss_weight=0.0035` | `xrecsys.py:545-590` |
| 负反馈头在负样本上屏蔽 | `mask_neg_feedback_on_negatives=True` | `recsys_model.py:1478,5273-5278` |
| 有负动作时屏蔽该候选正标签 | `mask_candidate_positive_when_negative_action_present` | `recsys_model.py:5235-5268` |
| logQ 校正 | `log_q_correction=True`、`log_q_num_bins=100_000_000` | `xrecsys.py:838` |
| 新用户判定 | `new_user_mask = 历史事件数 < 128` | `recsys_model.py:5066,5221` |

### 5.2 停留时长 = CREAD（分类 + 还原），不是回归一个秒数

连续头通用归一化 `gt_norm = clip(gt, 0, norm_scale)/norm_scale`（`loss_recsys.py:68-107`）。CREAD 在此之上分两步——阈值几何级数（`loss_recsys.py:110-125`）+ 分类与还原 loss（`:128-187`）：

```
ratio       = norm_scale / log_min_threshold
thresholds[k] = log_min_threshold * ratio^(k/(num_thresholds-1)), k=0..K-2；末尾追加 norm_scale
targets_k   = 1[gt > threshold_k]
cls         = mean_k BCE(sigmoid(logit_k), targets_k)
restored    = Σ_k sigmoid(logit_k) * delta_k,  delta_k = scale*(t_k^p − t_{k−1}^p)
              # _decode_cread, recsys_model.py:3639-3681
restoration = huber(|restored − clip(gt,0,norm_scale)| / norm_scale,
                    delta = cread_huber_delta_sec / norm_scale)
loss        = cls + restoration_weight * restoration
```

即 **30 个「停留是否超过 t_k 秒」的二分类器 + 一个把分类概率还原成秒数的 Huber 辅助项**。这是 2026-10-08「改进停留时长预测」changelog 条目在代码里的落地。

| 变体 | 关键参数 | 生产 loss 权重 | 证据 |
|---|---|---|---|
| `dwell-time-cread` | `norm_scale=120.0`，**排除 GALLERY** | **0.1** | `xrecsys.py:885-943,339` |
| `dwell-time-cread-immersive` | `norm_scale=240.0`，**仅 GALLERY** | **0.1** | `xrecsys.py:885-943,340` |
| `click-dwell-binary` | `binary_threshold=10.0` 秒、`norm_scale=60.0` | **1.0** | `xrecsys.py:336`；装配 `:909` |
| `dwell-time-tweedie` | `tweedie_power=1.5`、`output_cap=300.0`、仅 GALLERY、norm 300 | **0.0（关）** | `xrecsys.py:337`；`loss_recsys.py:215-246` |
| `dwell-time-mae` | norm 30 | **0.0（关）** | `xrecsys.py:338` |

**勘误**：`click-dwell-binary` 的 fallback 是 0.0（`xrecsys.py:909` 的 `mparams.get("click_dwell_loss_weight", 0.0)`），但生产 base 显式写 **1.0**（`xrecsys.py:336`）且 `home_direct_packed` 未覆盖——**只读 fallback 会误判为「关闭」**。只有 `immersive_page_rl` 系列把它设成 0.0（`xrecsys.py:464`）。

CREAD 通用默认：`log_min_threshold=2.0`、`num_thresholds=30`、`restoration_weight=0.5`、`restoration_loss="huber"`、`huber_delta_sec=5.0`（`recsys_model.py:458-541`）。条件连续头：`HOME_VIDEO_CONTINUATION_SECS`(idx 3) 以 `CLIENT_TWEET_VIDEO_OPEN` 为条件、`HOME_PROFILE_VISIT_SECS`(idx 0) 以 `CLIENT_TWEET_CLICK_PROFILE` 为条件，同样 CREAD、`norm_scale=300.0`（`xrecsys.py:269-315`）——**没发生条件动作的样本不进这两个头的 loss**。

### 5.3 模型内安全过滤：生产关闭

`safety_filter_mode ∈ {off, hard, soft}`，生产 **`"off"`**；`safety_filter_bits=0b11`、`soft_weight=0.0`、`apply_to_candidates=True`、`apply_to_history=False`（`recsys_model.py:1507-1511`）。实现：`hard` → `padding_mask & ~flagged`；`soft` → 权重乘 `soft_weight`（`phoenix/xrex/data/recsys/safety_filter.py:23-35`）。**这是训练/打分侧的开关，线上风控靠 VF，不靠它。** 两个 bit 对应哪些标签**不公开**（`safetyLabelMaskSeq` 只是 int64 列，`data/recsys/feature_config.py:164-208`）。

---

## 6. 召回双塔：user 是 transformer，tweet 不是

配置 `phoenix/xrex/configs/xrecsys_two_tower.py:252-351`。

| 部件 | 结构 | 证据 |
|---|---|---|
| **user tower** | 8 层 transformer，`emb_size=1024`、`emb_table_width=1024`、`query_heads=16`、`kv_heads=4`、`history_seq_len=1023`、`effective_sequence_len=513`、`right_anchored_rope=True`、`use_seqpack=True`、`transformer_output_only=True` | `xrecsys_two_tower.py:252-351,851-852` |
| user pooling | **`user_query_heads=4`**，4 个 query head 做带 recency 衰减的 attention pooling：`logits = content − gamma*from_newest/QUERY_HEAD_RECENCY_SCALE_TOKENS`（scale=16.0） | `xrecsys_two_tower.py:252-351`；`recsys_two_tower_model.py:2193-2199,71` |
| **tweet tower** | **不是 transformer**：`RecsysCandidateTower._project_then_sum` → 各 token 独立线性投影后**求和** → **L2 归一化**。输入 token 只有 **author 双 hash embedding（2 个）+ 1 个 SID token**，因为生产 `use_post_embedding=False`、`use_user_embedding=False`、`use_post_sid=True`；断言「两者至少一个为真」 | `recsys_two_tower_model.py:224-374,292-364,1897-1922,1924-1936,1945-1947`；`xrecsys_two_tower.py:331-333` |
| 相似度 | 归一化向量点积 = cosine，`users @ posts.T`；另有 MoL scorer（`mol_item_components=1`、`mol_item_adapter_rank=64`、`mol_gate_hidden=32`、`mol_conditioned_gate=True`） | `recsys_two_tower_model.py:2424-2425`；`xrecsys_two_tower.py:316-319` |
| item 池 | `max_posts=28_672_000`（home+immersive combined）；immersive 单独 `40_960_000`；candidate tower 默认 `10_240_000` | `xrecsys_two_tower.py:330,396,937` |

**一条帖子在召回侧的向量 = 作者身份 + 一个语义 ID**，没有正文 transformer、没有 post id embedding。这解释了为什么召回阶段「谁发的 + 内容语义簇」比正文措辞更重要。

训练目标 sampled softmax / InfoNCE（`recsys_two_tower_model.py:1079-1424`）：

| 项 | 值 | 证据 |
|---|---|---|
| 负样本 | **in-batch negatives** + **64 个 global negatives**（`num_global_negatives_per_example=64`、`num_negatives_per_example=0`） | `:1136-1151,1171-1185`；`xrecsys_two_tower.py:252-351` |
| 温度 | `warm_scores = raw / temperature`，**`fixed_temperature=0.006`**（固定，不学） | `:1243-1244`；`xrecsys_two_tower.py:323` |
| logQ 校正 | `sampling_weight = 1/tweet_counts`，`logq_correction = log(sampling_weight) * logq_correction_scale`，**scale=2.0** | `:1246-1259,2943` |
| 假负样本屏蔽 | `mask_in_batch_false_negatives=True`（同帖 hash 命中 → -INF） | `:1293-1303`；`xrecsys_two_tower.py:322` |
| 自身负样本偏移 | `true_neg_scores = self_scores + own_negative_logit_offset`，**offset=-2.0** | `:1322-1326`；`xrecsys_two_tower.py:325` |
| 用户权重 | `positive_count_user_weight_power=0.5` | `:1390-1411` |
| hard / soft negatives | hard：`REPORT, NOT_INTERESTED_IN, SEE_FEWER, UNFOLLOW_AUTHOR, BLOCK_AUTHOR, MUTE_AUTHOR, NOT_RELEVANT`；soft：`CLIENT_TWEET_RECAP_NOT_DWELLED` | `:2984-2994,2996-3000` |
| 3 个候选头 | `head_names=["home","immersive","ld"]`、`num_candidate_heads=3`；权重 **`w_fav=1.0` / `w_ld=0.75` / `w_tweet_click=0.0`**；`home_only` 变体只留 `["home","ld"]` | `xrecsys_two_tower.py:295-296,297,522-536`；`recsys_two_tower_model.py:3054-3056` |
| 训练 | `lr=2e-3`、`emb_learning_rate=0.2`、`empty_history_user_dropout_rate=0.1`、`dense_params_ema_decay=0.99`、H100 `bs_per_device=480, ep=128` | `xrecsys_two_tower.py:272-274,326,430-434` |

**`tweet_click` 头权重 0.0**：点击本身在召回目标里不计分。

---

## 7. 「训练去 surface 用户真正读完的帖子」在代码里的落点

三处联动：

1. **专门的 long-dwell 头**：`ld_positive_actions = [CLIENT_TWEET_RECAP_DWELLED]`（`xrecsys_two_tower.py:294`；`recsys_two_tower_model.py:3036-3038`），`w_ld=0.75`，仅次于 fav 的 1.0。
2. **开关**：`ld_label_exclude_clicks` 默认 **False**（`xrecsys_two_tower.py:246`），在 `xrecsys_two_tower_home_only` 配置里置 **True**（`:530`）→ 触发 `_drop_click_only_long_dwell`（`phoenix/xrex/data/recsys/recsys_batch.py:975-976`）。
3. **标签重写规则**（`recsys_batch.py:209-227`，核心）：

```python
keep = VideoQualityView | QuotedTweetVideoQualityView
     | ((dwell_secs >= 10.0) & 存在任一 qualifying action)
actions[..., ClientTweetRecapDwelled] &= keep
```

`dwell_secs = continuous_actions[..., 1]`（即 `DWELL_TIME`），`_LD_DWELL_THRESHOLD_SECS = 10.0`（`recsys_batch.py:206`）。**qualifying = 全部 action 减去两类**：

| 排除集合 | 内容 | 证据 |
|---|---|---|
| `_LD_NON_QUALIFYING_ACTIONS`（18 个） | `ClientTweetRecapDwelled` / `ClientTweetRecapNotDwelled` 自身 + 全部负反馈：`ClientTweetReport, ClientTweetNotInterestedIn, ClientTweetSeeFewer, ClientTweetBlockAuthor, ClientTweetMuteAuthor, ClientTweetMuteConversation, ClientTweetNotRelevant, ServerTweetReport, ServerProfileUnfollow, ServerProfileBlock, ServerTweetUnfav, ServerTweetUnreply, ServerTweetUnquote, ServerTweetUnretweet, ClientTweetUnfollowAuthor, ClientTweetUnbookmark` | `recsys_batch.py:179-198` |
| `_LD_CLICK_ACTIONS`（5 个） | `ClientTweetClick, ClientQuotedTweetClick, ClientTweetPhotoExpand, ClientQuotedTweetPhotoExpand, ServerTweetPostUnexplored` | `recsys_batch.py:199-205` |

**结论：光「点开链接 / 展开图片」撑出来的长停留不算「读完」。** 要保留 `RECAP_DWELLED` 正标签，必须 **停留 ≥10 秒且同时有实质互动**（fav/reply/quote/retweet/bookmark/share/follow…），**或者是视频有效播放（VQV）**。

这是「注意力优于点击」在代码里最硬的证据：**click-only 的长停留被从召回正样本里剔掉了**。注意 scope——该重写由 `ld_label_exclude_clicks` 控制，仓库里显式打开的是 `home_only` 配置。

---

## 8. Thunder：关注内没有算法

`score_recent` 就是倒序时间排序 + take（`thunder/thunder_service.rs:339-343`）：

```rust
light_posts.sort_unstable_by_key(|post| Reverse(post.created_at));
light_posts.into_iter().take(max_results).collect()
```

只接受 `"" | "recent" | "default" | "latest"` 四种 algorithm，其他值告警后仍走 `score_recent`（`thunder_service.rs:308`）。容量与窗口（`thunder/config.rs` 全 14 行）：

```
MAX_POSTS_TO_RETURN           = 1200   // :1   单次返回上限
MAX_VIDEOS_TO_RETURN          = 600    // :2
MAX_INPUT_LIST_SIZE           = 10000  // :3   following/exclude 列表截断
MAX_REPLY_POSTS_PER_AUTHOR    = 30     // :5
MAX_ORIGINAL_POSTS_PER_AUTHOR = 50     // :6
MAX_VIDEO_POSTS_PER_AUTHOR    = 100    // :7
MAX_TINY_POSTS_PER_USER_SCAN  = 500    // :8   每作者扫描深度
MAX_POSTING_LIST_SIZE         = 5000   // :12  每作者每列表容量
TRIM_FRACTION                 = 5      // :14  分片清理
post_retention_seconds        = 172800 // args.rs:48-49（48 小时）；post_store.rs:646-650
qps_limit                     = 8000   // args.rs:90-91，超限 resource_exhausted（thunder_service.rs:156-161）
```

关键行为：

- 插入即过滤超龄 `p.created_at < now && now - p.created_at <= retention_seconds`（`post_store.rs:132-135`）；`is_original = !is_reply && !is_retweet`（`:161`）；每列表 `while len() >= 5000 { pop_front() }`（`:181-185,190-194,214-218`）；清理按 `user_id % 5` 分片，`len() > 5000 || age > retention` 即淘汰（`:501-606,547,554-555`）。
- 视频资格：转推可继承源帖视频（源帖非回复时），**回复永远不进视频池**（`post_store.rs:198-210`）。
- 取回：倒序遍历 → 排除已看 → `.take(500)`（`:328`）→ 丢弃「转推观察者自己的帖」（`:337-339`）→ 回复资格过滤（回复原创帖，或 reply-to-reply 且 `in_reply_to_post_id == conversation_id` 且被回复者已关注，`:341-365`）→ `.take(max_per_user)`（`:367`）。
- 服务端 per-author clamp `min(n,50)` / `min(n,30)`（`thunder_service.rs:236-245`）；home-mixer 传 `per_author_limits: None`，走服务端默认（`sources/thunder_source.rs:32-41`）。
- **硬编码黑名单 3 个账号**：`1720665183188922368`(@grok)、`1909390269533011968`(@gork)、`1999031187604717568`(@products)（`thunder_service.rs:32-40`，过滤 `:276-280`）。

**结论：关注内是一个 48 小时新鲜度池 + 每作者配额，所有模型打分都发生在后面的 Phoenix 阶段。**「关注了就一定看到」不成立——Thunder 只保证你有机会进候选。

---

## 9. SimClusters：社区聚类召回

### 9.1 规模、生成与稀疏度

模型版本 **`Model20M145K2020 = "20M_145K_2020"`** → 2000 万用户 / **14.5 万集群**（`simclusters/simclusters_v2/common/ModelVersions.scala:9`）。KnownFor 作业 **每周重建**（`batchIncrement = Days(7)`，`firstTime=2020-10-04`），输入是**基于关注关系的近似 cosine 相似度图** `FollowingsCosineSimilaritiesManhattanSource(".../approximate_cosine_similarity_follow")`，`minActiveFollowers=400`、`topK=20000000`、`maxNeighbors=400`、`maxEpochs=3`、`wtCoeff=10.0`、`squareWeightsEnable` 开关，并**从上一版快照 warm start**（`scalding/update_known_for/UpdateKnownFor20M145K2020.scala:37,39,43-44,57,58,60,62,64,65,67-76,81`）。**实际聚类求解器 `UpdateKnownForSBFRunner` 属外部 WTF 包，不在本仓库**（`:78-92`）。

表示 = 平行稀疏数组 `clusterIds`（按 score 降序）+ `sortedClusterIds/sortedScores`（按 id 排序供 merge-join）（`common/SimClustersEmbedding.scala:14-17`）；`cosineSimilarity` = 两个 L2 归一化数组点积（`:144-150`）。显式 K（`simclusters_v2/summingbird/common/Configs.scala`）：

```
topKTweetsPerCluster   = 1600   // :51  每集群倒排列表保留 1600 条帖子
topKClustersPerEntity  = 50     // :53  每个 entity（user/author）保留 50 个集群
topKClustersPerTweet   = 400    // :55  每条帖子保留 400 个集群
scoreThresholdForEntityTopKClustersCache  = 0.02   // :57
scoreThresholdForTweetTopKClustersCache   = 0.02   // :59
scoreThresholdForClusterTopKTweetsCache   = 0.001  // :61
scoreThresholdForClusterTopKEntitiesCache = 0.001  // :63
HalfLife = 8.hours              // :39  分数指数衰减半衰期
MinFavoriteCount = 8            // :65
OldestTweetInLightIndexInMillis      = 1.hours  // :67
OldestTweetFavEventTimeInMillis      = 3.days   // :69
OldestVideoTweetFavEventTimeInMillis = 7.days   // :73
```

截断实现：`computeTweetTopKClusters` 先 `score < 0.02 → None` 再 `.sortedReverseTake(400)`；`computeClusterTopKTweets` 先 `score < 0.001 → None` 再 `.sortedReverseTake(1600)`（`scalding/offline_job/SimClustersOfflineJob.scala:113-165`）。**稀疏度：一条帖子最多挂 400 个集群（14.5 万里占 0.28%）；一个集群倒排列表最多 1600 条帖子。**

### 9.2 进池门槛（对小号最关键）

- **帖子进入 persistent 索引需 `favoriteCount >= 8`**（`summingbird/storm/PersistentTweetJob.scala:23,50-57`）。
- producer（作者）embedding 需 `faverCount > minNumFaversForProducer = 100`（`scalding/embedding/ProducerEmbeddingsFromInterestedIn.scala:474`；relaxed 变体 `minNumFavers=15`，`AggregatableLogFavBasedProducerEmbeddings.scala:137`）；producer 侧另一套稀疏度 `numClustersPerNoun=60`、`numNounsPerClusters=500`、`thresholdForEmbeddingScores=0.01`（`AggregatableProducerEmbeddings.scala:27-31`）。
- 用户兴趣阈值 `favScoreThresholdForUserInterest = 0.3`（2020 版；updated 1.0，dec11 0.15）（`Configs.scala:27-32`）；帖子 embedding 类型 `EmbeddingType.LogFavBasedTweet`、`usingLogFavScore=true`，视频版 `LogFavBasedVideoTweet`（`SimClustersProfile.scala:142-150,152-160`）。

**含义：SimClusters 不是新号通道。** 8 个赞才进持久索引，作者要有 100 个点赞者才有 producer embedding。

### 9.3 在线 ANN

客户端常量（`home-mixer/sources/simclusters_source.rs`）：`MAX_SANN_CANDIDATES=10_000`、`MAX_RESULTS=800`、`SOURCE_EMBEDDING_TYPE=LOG_FAV_LONGEST_L2_EMBEDDING_TWEET`、`CANDIDATE_EMBEDDING_TYPE=LOG_FAV_BASED_TWEET`、`MODEL_VERSION=MODEL_20M_145K_2020`、`ANN_MAX_NUM_RESULTS=200`、`ANN_MIN_SCORE=0.0`、`ANN_MAX_TOP_POSTS_PER_CLUSTER=800`、`ANN_MAX_SCAN_CLUSTERS=50`、`POST_ANN_MIN_SCORE=0.5`、`MAX_SEED_AGE=90 天`。

流程：seeds = 显式+隐式互动信号按 `Reverse(engaged_at_ms)` 排序去重（`:288-312`，年龄 ≤90 天 `:226`）→ `max_per_query = max(10000/seed数, 1)`（`:233`）→ ANN 用 `ScoringAlgorithm::COSINE_SIMILARITY`（`:329`）→ 过滤 `score > 0.5`（`:245`）→ `interleave_by_post_id` 轮转合并 → `.truncate(800)`（`:251-252`）。本地 moka 缓存 2_000_000 条 / TTL 600s（`:56-59`）。

服务端（`simclustersann/candidate_source/`）：`sourceEmbedding.truncate(50).getClusterIds.toSet` → `clusterTweetCandidatesStore.multiGet` → 近似 cosine（`SimClustersANNCandidateSource.scala:63-96`）；每集群 `.take(maxTopTweetsPerCluster)`（`ApproximateCosineSimilarity.scala:77`），排除 seed 自身（`:80`），累加 `score * sourceClusterScore`（`:84`）与 `score²`（`:86`），最后 `.filter(_._2 >= minScore).sortBy(-_._2).take(min(maxNumResults, 1000))`（`:128-131`，`MaxNumResultsUpperBound=1000` 在 `:32`）。

**在线每集群只扫前 800 条，离线索引存 1600 条**——后半段在线永远扫不到。ANN 服务端集群配置数值由外部 `relevance_platform` 包解析，**不公开**（`ClusterConfigModule.scala`）。

---

## 10. DPP：不改分数，只决定谁活下来

核函数（`vm-ranker/dpp.rs:103-152`）：

```
max_score = inputs[top_indices[0]].score.max(1e-6)
theta     = config.theta.clamp(0.0, 1.0 - 1e-6)
alpha     = theta / (2.0 * (1.0 - theta))          # :105-106
q_i       = score_i / max_score                    # seed 固定 q=1.0，:129-138
qf_i      = exp(alpha * q_i)
L_ii      = qf_i²                                  # :144
cos_ij    = dot(e_i,e_j)/(‖e_i‖‖e_j‖)              # :147-151
L_ij      = qf_i * qf_j * cos_ij                   # :152
```

标准 quality×similarity kernel **`L = Diag(q)·S·Diag(q)`，`q_i = exp(alpha · score_i/max_score)`**。

| 参数 | 生产值 | 来源文件 |
|---|---|---|
| `DppEnabled` / `TopicDppEnabled` | true / false | `vm-ranker/params.rs:265-270,271-276` |
| **`DppTheta`** | **0.65** → **alpha ≈ 0.9286** | `vm-ranker/params.rs:277` |
| **`DppMaxSelectedRank`** | **150**（只对分数前 150 名做 DPP） | `vm-ranker/params.rs:278-283` |
| `DppGreedyOrder` / **`DppWindow`** | false / **0（滑窗模式关闭）** | `vm-ranker/params.rs:284-289,290` |
| CLI 默认（被 feature switch 覆盖） | `dpp_theta=0.5`、`dpp_top_k=50`、`embedding_dim=1024` | `vm-ranker/args.rs:18-19,21-22,27-28`；覆盖点 `scoring/mod.rs:59-71` |

θ→1 时 alpha→∞（纯分数），θ→0 时 alpha→0（纯多样性）。贪心最大化 log-det：首个取对角线最大者（或 pinned seed），`log_det = ln(first_val)`（`dpp.rs:300`），增量 Cholesky `cv = L_ii − Σ_j cholesky[j][i]²`（`:323-327`），`best_vol <= 1e-6` 即停并记 `rank_exhausted`（`:334-338`；整体 `:269-360`）。滑窗替代模式（`DppWindow>0` 时，`:362-414`）：`weights[d]=0.5^(d/half_distance)`（`:373`）、`penalty=min(cos²+(同 L1 SID ? sid_lambda : 0), 1.0)`（`:383`）、`gain_i = quality_i × Π(1 − w_d·penalty)`（`:403`），quality 用 `exp(2α·score/max_score)`（`:112`）。**生产 window=0，这条路径不生效。**

### 10.1 「DPP 牺牲分数换多样性」是错的提法

`serve`（`dpp.rs:187-261`）**不修改任何分数**：选中的 id 按**原始分数**重新排序，再与排序后的分数 zip 回去（`:195-215`），指标写死 **`DPP_RESCALING = "unchanged"`**（`:244-246`）。未选中的候选在 `rank_with_memo` 里被置 **score = 0.0**（`scoring/dpp_model.rs:265-268`）。

**DPP 是选择器/过滤器，代价体现在「哪些帖子活下来」，不是「每条帖子扣多少分」。** 埋点是 `DPP_AVG_SIMILARITY before/after`（`:232-242`）与 `DPP_TOP_K_OVERLAP`（`:248-258`），**没有线上实测数值公开**。单测印证：embedding 完全相同 → 只有最高分那条存活（`dpp.rs:502-521`）；正交向量被提拔（`:524-546`）；`filter_only_preserves_original_scores`（`:549-581`）；seed 压制近重复但不占 top_k 名额（`:609-659`）。

| 行为 | 实现 | 证据（`vm-ranker/scoring/dpp_model.rs`） |
|---|---|---|
| 缺 embedding | `random_unit_embedding(1024)` + `embedding_missing=true`，norm 记 1.0 → **既不惩罚别人也不被别人惩罚** | `:26-54` |
| **转推共用源帖 embedding** | `embedding_id = retweeted_tweet_id if != 0 else tweet_id` → 同一条内容的多次转推完全相似，**只留一条** | `:83-87` |
| **跨请求多样性窗口** | `HISTORY_MAX_AGE_MS = 10*60*1000` → 只看**最近 10 分钟**已下发内容，按 `served_time_ms` 分页、页内逆序 | `:14,132-157` |
| seed 与 L1 | `seed_tweet_id`（score 0.0、pinned）压制与上一条已下发内容近重复的帖；`l1 = semantic_ids.first()` 仅用于滑窗 SID 惩罚，且只在 `sid_lambda > 0` 时才拉取 | `:106-130,100`；`scoring/mod.rs:76-84` |

**真正的乘法扣分不在 DPP**：作者多样性衰减 `(1−floor)·decay^k + floor` 与 OON 折扣在 `xai-value-model/scoring.rs:304-306,308-325,327-336`，参数在 `vm-ranker/params.rs:199-216,241-246`。**数值与运营含义见 `02-scoring-ranking.md`，本文不复制。** 顺序上它们在 DPP 之前——DPP 看到的 `score` 已是折后分。

---

## 11. 索引准入：一条帖子为什么永远进不了召回池

「我的帖子零曝光」最实用的一节。准入发生在 `phoenix-rankall-strato`，**在线之前**。

### 11.1 触发与限频

fav 事件 → `nextPowerOfTwo(count)` 阈值门控 → 发 `PhoenixRankAllIndexingRequest{postId, eventSource=Fav}` 到 `favIndexingEventKafkaTopic`（`columns/favoriteEventProcessor.strato:14-21`，缓存路径 `:120-134`，非缓存 `:135-148`）。**unfavorite 事件直接忽略**（`:155-157`）。文件自述「rate-limited per tweet by power-of-two favorite-count thresholds」（`:173-177`）。阈值缓存 `MemcacheColumn ttl = 50.hours`（`tweetUpdateThresholdsCache.strato:19`）。另一条入口：`columns/phoenix_rank_all/postCreationEventProcessor.strato:7-15` 收 ContentUnderstandingMetadataV2 事件 → `eventSource=PostCreation`。

门控（`lib/eventProcessing.strato:42-60`）：`!engagementsAgedOut && !tweetAgedOut && passedThreshold && belowMaxEngagements && !updatedRecently`，常量 `maxTimeSinceFirstUpdate=48.hours`（`:28`）、**`minTimeSinceLatestUpdate=1.minute`（防抖）**（`:30`）、**`maxTweetAge=49.hours`**（`:32`）、`maxEngagements=1073741824`（2^30，`:34`）、**`minEngagements=32`**（`:36`）。

**含义：点赞数要跨过 2 的幂台阶（1→2→4→8→16→32…）才重新索引，同一帖 1 分钟内只更新一次，发帖 49 小时后彻底停止。** 一条帖子一生中被重新评估的次数是有限的。

### 11.2 准入判定树

`columns/phoenix_rank_all/phoenixRankAllCandidateProcessor.strato:538-596`：

```scala
isCommunityPost / isRepost                                             // :538-539
if (eventSource == Fav && !isCommunityPost && !isRepost)
  buildSearchUnfilteredIndex(...)                                      // :541-542 需 favCount>=1
isReply / isAdultPost = isNsfwPost(unifiedPostAnnotations)             // :545-546
shouldDropPostByVF = eventProcessing.shouldDropPostByVF(postId)        // :547  ← 先查 VF
shouldDropPost = shouldDropPostByVF || isAdultPost                     // :548
if (isCommunityPost)  numSkippedCommunity                              // :549-550
else if (isReply) { isSelfReply → skip; shouldDropPost → numSkippedFilteredReplies;
                    else 1FavReplyIndex + 32FavReplyIndex + Metadata }  // :551-561（仅 eventSource==Fav）
else if (isRepost)    numSkippedReposts                                // :564-565
else if (shouldDropPost) { hasImmersiveVideo && Fav && isAdultPost
                             → NsfwVideoIndex + Metadata + MMEmbMetadata // :567-570
                           else numSkippedPosts }                      // :572
else Fav → 1FavIndex/1FavIndexBackup/1FavTopicIndex/32FavIndex
           (+video/1fav_video/imagine/ai_video_* 若有合格视频) + Metadata // :576-589
     PostCreation → PostCreationIndex(+video/ai_video) + Metadata       // :590-596
```

**永不进主召回索引的 6 类**：

| # | 类别 | 判定 | 证据 |
|---|---|---|---|
| 1 | **社区帖** | `communities.nonEmpty` → 全索引跳过 | `eventProcessing.strato:256-258`；processor `:549-550` |
| 2 | **转推** | `coreData.share.nonEmpty` → 全索引跳过（只可能以源帖身份被索引） | `eventProcessing.strato:175-180`；processor `:564-565` |
| 3 | **自回复** | `reply.inReplyToUser == core.user` → 跳过 | `eventProcessing.strato:242-246`；processor `:554-555` |
| 4 | **VF 判 drop** | 见 §11.4 | processor `:547-548,572` |
| 5 | **NSFW 帖** | `tweetBoolMetadata.isNsfw` → 跳过主索引；**唯一例外**：NSFW + 合格沉浸式视频 + Fav 事件 → 只进独立的 `nsfw_video` 索引 | `eventProcessing.strato:332-340`；processor `:567-570` |
| 6 | **回复** | 只进 `1fav_reply` / `32fav_reply` 专用索引，不进主 `1fav`/`32fav`；且**只有 `eventSource == Fav` 时才建** | processor `:551-561` |

### 11.3 索引级门槛与保留窗口

| 索引 | 门槛 | 证据 |
|---|---|---|
| `search_unfiltered` / `1fav` | `favoriteCount >= 1` / 无条件（favCount 为 0 只记一个 race 计数器） | processor `:46-60,78-89` |
| **`32fav`** | **`favoriteCount >= 32`** | processor `:62-76` |
| 视频类（`video`/`1fav_video`/`imagine`/`ai_video_*`） | `hasValidImmersiveVideo` = **所有 media 类型 ∈ {TweetVideo, AmplifyVideo} 且时长 > 10s** | processor `:263-275,311-323,397-411`；`eventProcessing.strato:23-24,403-418` |
| 作者资格 | **`nsfwUser == false && nsfwAdmin == false`** | `eventProcessing.strato:157-161` |
| topic / AI 视频 | 6 个实验分支 `1fav_topic`, `1fav_topic_option_1..5`，作者-主题匹配用最近 15 条帖、阈值 0.90/0.75/0.50；AI 视频分 `ai_video_self`（UserDeclared）与 `ai_video_detected`（C2paClient/GrokSignature/AgentApplied） | processor `:116-165,213-261,356-369`；`eventProcessing.strato:475-479` |

保留窗口（`phoenix-rankall/src/config/mod.rs:168-234`，单位小时）：

| pipeline | 窗口 |
|---|---|
| **Main** | post_creation 24；1fav 24 & 48；1fav_video 48 / bounded(48→96) / bounded(96→336) / bounded(96→720)；32fav 24；1fav_reply 24；32fav_reply 24；video 48/96/168/336/720；nsfw_video 48/168；**evergreen_video 与 evergreen_nsfw_video 各 `24*365*5`（5 年）** |
| Topic / Metadata | 1fav 24 + 6 个 topic 分支各 24 / 24、48、72 |
| Sid | 1fav 24、1fav_reply 24、1fav_video 48+bounded、video 6 / bounded(6→48) / 48 / 96 / 336、nsfw_video 48/168/336、evergreen_video 5y、imagine 96、ai_video_self 与 ai_video_detected 各 24/48/168 且 `.excluding_posts_in("nsfw_video")` |
| SidTail | tail 24 |

Kafka 路由：Main|Sid → `phoenix_rank_all_indexing_event`；Topic → `..._backup`；Metadata|SidTail → `phoenix_rankall_metadata_event`；Analysis → `home_mixer_phoenix_scored_candidates`（`config/mod.rs:147-155`）。其他常量：`seek_hours=12`（`:43-44`）、`dump_interval_secs=180`（`:55-56`）、`versions_to_keep=3`（`:58-59`）、`score_prefix="phoenix.HomeExperiment1Lap7."`（`:64-69`）、`sid_min_post_age_seconds=180.0`（`:83-84`）、`sid_backfill_qps_cap=800_000`（`:92-93`）、**`tail_max_author_followers=1000`**（`:104-105`）、`tail_min_fav_count=0`（`:107-108`）。二次黑名单 `blacklisted_post_ids.txt` / `blacklisted_author_ids.txt`，`is_blocked = post_id ∈ set || author_id ∈ set`（`src/processor/blacklist.rs:14-15,32-34`）；`post_id==0 || author_id==0 || index_name.is_empty()` 的记录直接丢（`src/processor/main_processor.rs:52-55`）。

**`tail_max_author_followers = 1000`：长尾索引只收粉丝数 ≤1000 的作者。** 这是仓库里少见的、明确按作者规模分流的准入参数——小号有一条专属长尾通道，但它同样受 24 小时窗口和上面全部门槛约束。

### 11.4 索引期 VF 调用：没有观察者上下文

`lib/eventProcessing.strato:260-279`：decider `enable_vf_rust_should_drop_tweet` 为真 → `#<visibility/xai/shouldDropTweet>.fetch(postId, {safetyLevel = TimelineHomeRecommendations})`（`:268-269`）；否则 → `#Tweet<visibility/service/shouldDropTweetV2>.fetch(postId, {safetyLevel = TimelineHomeRecommendations, forUserId = None})`（`:275-276`）。**两条路径都出错默认 false（放行）。**

可以确定：**调用只带 postId + safetyLevel**；**legacy 路径显式 `forUserId = None`**；**fail-open**。**不能确定**：没有观察者时 `ViewerFollowsAuthor` / `ViewerBlocksAuthor` / 年龄 / 设置这类 viewer-relative 条件如何解析，因此**哪些 audience-gated 规则会在索引期真正命中，无法从本仓库判定**——不要据此断言某条 audience 规则一定在索引期生效。规则清单本身见 `visibility-filtering/rules/levels.rs:338-381`。

---

## 12. 观察者行为序列

两个 hydrator 走同一个 UAS 客户端，参数不同：

| | scoring（排序） | retrieval（召回） |
|---|---|---|
| 长度上限 | `MaxSeqLengthScoring = 1024` | `MaxSeqLengthRetrieval = 1024` |
| aggregation type | **`DENSE_WITH_LONG_DWELL_HOME_EXCURSION`** | **`DENSE_WITH_LONG_DWELL`** |
| model type | `UaasModelType::Ranking` | `UaasModelType::Retrieval` |
| window / 格式 | `UAS_WINDOW_TIME_MS = 300_000`（5 分钟）/ `ResponseFormat::Arrow` | 同 |

证据：`home-mixer/params/param.rs:1130-1140`（两个 1024）、`:175-186`（两个 aggregation type）、`params/config.rs:39`（300_000）；`query_hydrators/scoring_sequence_query_hydrator.rs:92-118`（`:106` window、`:107` max_len、`:110` Arrow、`:113` Ranking）；`query_hydrators/retrieval_sequence_query_hydrator.rs:49,51,58`；客户端签名第 3 参 `window_time_ms: u32`、第 4 参 `max_sequence_length: u32`（`clients/user_action_aggregation_client.rs:61-73`，请求体 `:239-251`，`client_id="xai-home-mixer"`）。

enum 数值：`DENSE=2`、**`DENSE_WITH_LONG_DWELL=15`**、**`DENSE_WITH_LONG_DWELL_HOME_EXCURSION=30`**、`DENSE_WITH_LONG_DWELL_FAIR_VIEW=32`、`DENSE_WITH_RECENT_IMPRESSIONS=34`（`phoenix/python/common/xai-proto/proto/recsys.proto:2003-2039`，serving 侧镜像 `phoenix/crates/serving/xai-recsys-proto/proto/recsys.proto:2003-2039`）。两侧 fallback 均为 `DenseWithFavVqvCleaned`（`scoring_sequence_query_hydrator.rs:47`）。action 类型就是 §4 的 60 离散 + 8 连续，历史侧额外消费 enum 60+ 的非头 action。

**时间衰减不在 hydrator 里，在模型里**，四处：

| 机制 | 参数 | 证据 |
|---|---|---|
| log-dt Fourier 编码 | `RECENCY_LOG_DT_SCALE=15.0`、`RECENCY_FOURIER=8`，作用于 `RECENCY_ACTIONS` | `recsys_model.py:184-189` |
| `time_gap` 指数分桶 | `TIME_GAP_CARDINALITY=19`，边界 `60*2^k` 秒（k=0..16，1 分钟 → ~18 小时），`lr_scale=4.0` 且 zero_init | `recsys_feature_prep.py:51-52,73-78,1056-1069` |
| 双塔 query-head recency 惩罚 | `logits = content − gamma*from_newest/QUERY_HEAD_RECENCY_SCALE_TOKENS` | `recsys_two_tower_model.py:2193-2199` |
| 硬窗口 | `recent_positive_window_secs=900`（15 分钟）、`recent_positive_last_n=5`、`recent_positive_last_n_cap_secs=7200` | `recsys_model.py:1415-1417`；mask 构造 `:370-401` |

历史统计窗口 `STATS_HISTORY_WINDOW_DAYS=28`、`MS_PER_DAY=86_400_000`，`engaged_history_topics(sequence, request_time_ms − days*MS_PER_DAY)`（`scoring_sequence_query_hydrator.rs:21-22,60`）。

**诚实边界**：`UAS_WINDOW_TIME_MS=300_000` 是传给 UAS 的 `window_time_ms`。序列本身覆盖 1024 条历史事件，所以它**不是「只取最近 5 分钟行为」**；但**该字段在 UAS 服务端的确切语义不在本仓库，无法进一步确认**（只有客户端签名 `user_action_aggregation_client.rs:61-73`）。

---

## 13. hash-based vocab-free embedding（基础设施，不是触达政策）

核心实现（`phoenix/xrex/models/recsys_embedding.py:154-172`，numba njit）：

```python
raw      = (id * scales[j] + biases[j]) % modulus
out[i,j] = 0 if id == 0 else ((raw % (num_buckets - 1)) + 1)
```

**每个实体 2 个 hash 函数**（四个实体的 scales 列表都是 2 元素，`recsys_embedding.py:212-226`），**bucket 0 保留给 padding**，有效桶 `1 .. num_buckets-1`，`id == 0` 直接映射 0。典型 double hashing / Bloom embedding：用碰撞换词表，不维护 id→行号映射。生产桶数 **user 100_000_000 / item 100_000_000 / author 30_000_000 / ip 10_000_000**（`xrecsys.py:586-589`），hash 常数在 `xrecsys.py:174-185`；`HashKeys` dataclass 默认值只是 nano 规模（user/item 100_000、author 10_000、ip 0，`recsys_embedding.py:177-196`），生产由 `_make_cfg` 注入。

**单一共享大表 + 分段偏移**（`recsys_embedding.py:234-248`）：`offset_user = 1 + 64 = 65`（1 个 PAD + 64 个 action token），`offset_item = 65 + 100M`，`offset_author = 65 + 200M`，`offset_ip = 65 + 230M`；`input_vocab_size = round_up(240_000_061, INPUT_VOCAB_K=512) = 240_000_512`（`xrecsys.py:146-155,48-51`）。每行宽 `emb_table_width=1024`，投影升到 `emb_size=2560`。SID 第 7 层也用 hash 而非查表：`mixed = h*1540483477; mixed ^= mixed>>16; code = abs(mixed)%256 + 1`（`recsys_feature_prep.py:817-819`），同样避开 0。

---

## 14. 明确不在仓库里的东西

| # | 缺失项 | 已知边界 |
|---|---|---|
| 1 | SimClusters 145K 的**实际聚类求解器** | `UpdateKnownForSBFRunner` 属外部 WTF 包（`UpdateKnownFor20M145K2020.scala:78-92`）。仓库内 Louvain 只用于 topic 二次聚类，其 `cosine_similarity_threshold` / `resolution_factor` 是 CLI 必填参数，**无硬编码数值**（`scalding/embedding/twice/InterestedInTwice.scala:141-143`） |
| 2 | SimClusters ANN **服务端集群配置数值** | `ClusterConfigModule.scala` 通过外部 `relevance_platform` 包按服务名解析；线上数值只能取 home-mixer 客户端常量（§9.3） |
| 3 | **`window_time_ms=300_000` 在 UAS 服务端的语义** | UAS 实现不在仓库，只有客户端签名（`user_action_aggregation_client.rs:61-73`） |
| 4 | Phoenix 打分服务的 **batch/分片策略** | `PhoenixScorer` 一次性把 ≤2800 候选塞进单个 `candidate_sets[0]`（`phoenix_scorer.rs:102-114`；`util/phoenix_request.rs:309`），**Rust 侧无 chunk 逻辑**；`candidate_seq_len=64` + `seqpack_candidate_count=[128]` 暗示服务端按 64/128 打包，但调度代码未确认 |
| 5 | **`TOP_LOG_PROBS_NUM` 的数值** | 定义在外部 crate `xai_candidate_pipeline::...::phoenix_prediction_client`，本仓库只 import（`util/phoenix_request.rs:9,222`） |
| 6 | DPP「牺牲多少分」的**线上实测值** | 只埋点 `DPP_TOP_K_OVERLAP` 与 `DPP_AVG_SIMILARITY before/after`（`dpp.rs:232-258`）；分数不被修改，「牺牲分数」在代码层面不成立 |
| 7 | **`safety_filter_bits=0b11` 两个 bit 的标签含义** | `safetyLabelMaskSeq` 只是 int64 列（`data/recsys/feature_config.py:164-208`）；且生产 `safety_filter_mode="off"`，路径不生效 |
| 8 | 索引期 VF 的 **audience 解析行为** | 见 §11.4，`forUserId = None` 下 viewer-relative 条件如何判定无法从本仓库确定 |