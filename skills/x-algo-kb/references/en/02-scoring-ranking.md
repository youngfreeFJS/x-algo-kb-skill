# 02 · Scoring and Ranking: Why a Post Ranks Where It Does

> Evidence base: `xai-value-model/scoring.rs`, `xai-value-model/weights.rs`,
> `home-mixer/params/param.rs`, `vm-ranker/params.rs`
> `home-mixer/params/param.rs:1` states `last sync 2026-11-16T16:00:37Z`, so the
> values below are **current production defaults**, not illustrative numbers.

---

## 1. The formula in one line

```
final score = Σ(weight_i × predicted P(viewer takes action_i)) + 0.001
              then × author-diversity multiplier × out-of-network discount
              then DPP diversity reranking
```

**The single most important correction**: weights multiply **predicted
probabilities**, not **observed engagement counts**.

Upstream comment, `xai-value-model/scoring.rs:34-44`:

> Each weight multiplies the *predicted* probability of that action (P(favorite),
> P(repost), …) or a continuous value e.g. watch time -- the weights do not
> multiply raw engagement counts. One common misinterpretation is that you can
> read these weight ratios as count equivalences, e.g. the incorrect statement
> that "one report cancels 468 likes" -- this is incorrect.

Report carries a large weight because reporting is extremely rare (the comment
says its baseline probability is >1000x lower than a like). Without a large
weight the prediction could not influence ranking at all.

---

## 2. Full weight table (production defaults)

### 2.1 Positive actions

| Action head | Weight | Parameter | Evidence |
|---|---|---|---|
| `reply` | **5.0** | `rust_home_mixer_reply_weight` | `param.rs:453` |
| `quote` | **5.0** | `rust_home_mixer_quote_weight` | `param.rs:502` |
| `share_via_dm` | **5.0** | `rust_home_mixer_share_via_dm_weight` | `param.rs:493` |
| `follow_author` | **4.0** | `rust_home_mixer_follow_author_weight` | `param.rs:519` |
| `share` | 2.118 | `rust_home_mixer_share_weight` | `param.rs:488` |
| `retweet` | 1.0 | `rust_home_mixer_retweet_weight` | `param.rs:466` |
| `favorite` | **0.708** | `rust_home_mixer_favorite_weight` | `param.rs:451` |
| `click` | 0.274 | `rust_home_mixer_click_weight` | `param.rs:479` |
| `open_link` | 0.2 | `rust_home_mixer_open_link_weight` | `param.rs:480` |
| `dwell` (binary) | 0.05 | `rust_home_mixer_dwell_weight` | `param.rs:501` |
| `photo_expand` | 0.05 | `rust_home_mixer_photo_expand_weight` | `param.rs:471` |
| `quoted_click` | 0.05 | `rust_home_mixer_quoted_click_weight` | `param.rs:507` |
| `post_unexplored` | 0.015 | `rust_home_mixer_post_unexplored_weight` | `param.rs:525` |
| `video_open` | **0.0** | — | `param.rs:477` |
| `profile_click` | **0.0** | — | `param.rs:485` |
| `vqv` (video quality view) | **0.0** | — | `param.rs:487` |
| `share_via_copy_link` | **0.0** | — | `param.rs:499` |
| `quoted_vqv` | **0.0** | — | `param.rs:513` |
| `post_video` | **0.0** | — | `param.rs:531` |
| `grok_analyze` | **0.0** | — | `param.rs:537` |

### 2.2 Continuous values (durations, seconds)

| Term | Weight | Evidence |
|---|---|---|
| `click_dwell_time` | **0.385** | `param.rs:549` |
| `dwell_time` | **0.0075** | `param.rs:543` |
| `video_continuation` | 0.0 (hardcoded in home-mixer) | `value_model.rs:39` |
| `user_video_continuation` | 0.0 (hardcoded) | `value_model.rs:40` |
| `profile_visit_secs` | 0.0 (hardcoded) | `value_model.rs:41` |

**Mind the magnitude.** `click_dwell_time` is 0.385 per second. A predicted
10-second post-click dwell contributes 3.85; a 0.1 probability of liking
contributes 0.0708. **Dwell time outweighs likes by one to two orders of
magnitude.** This is the most underrated term in the current algorithm.

### 2.3 Negative actions

| Action head | Weight | Evidence |
|---|---|---|
| `report` | **-234.0** | `param.rs:570` |
| `mute_author` | **-58.8** | `param.rs:568` |
| `not_interested` | **-53.07** | `param.rs:556` |
| `block_author` | **-31.2** | `param.rs:562` |
| `not_dwelled` (scrolled past) | -0.02 | `param.rs:575` |

`report / favorite = 234 / 0.708 ≈ 330`. The README's "468" is an older value; the
comment was not updated alongside the parameter.

### 2.4 Why mass blocking/reporting cannot suppress your reach

`xai-value-model/scoring.rs:46-58` gives two official reasons:

1. **Personalization.** The model predicts whether *this viewer* will report, not
   a sum of counts. Reports from bad actors mainly affect recommendations for
   users *similar to those actors*, not for everyone.
2. **The action must occur on a post served in Home Timeline.**
   > For an account to count in the algorithms recommendation system, it must
   > take place on a post served in Home Timeline. Directly navigating to a post
   > (i.e., coordinating via groupchat) has no ranking impact.

**Consequence**: organizing a group chat to mass-report or mass-like a post has
**no ranking effect**, because those actions did not happen inside For You. The
same applies to engagement-pod liking.

---

## 3. Mutual-follow boost — the July 2026 change

### 3.1 Mechanism

```rust
// xai-value-model/weights.rs:127-134
pub fn reply_weight_for(&self, candidate) -> f64 {
    if boost != 0.0 && candidate.bidirectional_boost_eligible() {
        return self.reply + self.bidirectional_follow_reply_weight_boost;
    }
    self.reply
}
```

Production value: `BidirectionalFollowReplyWeightBoost = 15.0` (`param.rs:458`).

**For a mutually-followed author's original post, the reply weight goes from
5.0 → 20.0 — a 4x increase.**

### 3.2 Eligibility (all three required)

```rust
// xai-value-model/inputs.rs:20-22
pub fn bidirectional_boost_eligible(&self) -> bool {
    !self.is_reply && !self.is_retweet && self.is_mutual_follow_author
}
```

1. **Not a reply**
2. **Not a retweet**
3. **Mutual follow** (viewer follows author AND author follows viewer)

Implemented in `home-mixer/candidate_hydrators/bidirectional_follow_hydrator.rs`:
take the viewer's following list, then call `check_followed_by` on candidate
authors to confirm the reverse edge.

### 3.3 Official rollout timeline

From `docs/BIDIRECTIONAL_BOOST_CHANGE.md`:

| Date | Change |
|---|---|
| 2026-07-10 | A/B test; boost randomly assigned 5 / 10 / 15 / 20; most users at 0 |
| 2026-07-13 | Strong results → rolled out **20** broadly |
| 2026-07-24 | Lowered to **15**. Reason: during the World Cup users complained they saw too little discussion, much of which came from accounts they did not follow |

`bidirectional_follow_dwell_weight_boost` was tested in the same experiment but
**never shipped broadly**; production value 0.0 (`param.rs:464`).

### 3.4 What this means for growth

This is the actual algorithmic payoff behind "comment on other people's posts to
gain followers":

```
Comment on a larger account's post
  → author / other readers notice you → they follow back
  → mutual follow established
  → YOUR ORIGINAL POSTS get reply weight 5 → 20 in their For You
  → more likely to be surfaced to them → more genuine engagement → further spread
```

**Note**: the boost applies to **your original posts**, not to your replies.
Replies get no boost and do not enter the recommendation pool at all
(see `03-retrieval-filtering`).

---

## 4. The three multiplicative adjustments

### 4.1 Author diversity decay (anti-spam)

```rust
// xai-value-model/scoring.rs:304-306
pub fn diversity_multiplier(decay_factor, floor, exponent) -> f64 {
    (1.0 - floor) * decay_factor.powf(exponent) + floor
}
```

Production params (`vm-ranker/params.rs:200-216`): `enable=true`, `decay=0.5`,
`floor=0.25`.

`exponent = k` = this post's rank **among all candidates by the same author,
ordered by score** (`scoring.rs:308-325`).

| Which post by same author | k | Multiplier |
|---|---|---|
| 1st | 0 | **1.000** |
| 2nd | 1 | **0.625** |
| 3rd | 2 | **0.4375** |
| 4th | 3 | 0.34375 |
| 5th | 4 | 0.296875 |
| Nth | → | approaches **0.25** (floor) |

**Implication**: posting several times in one window discounts the 2nd post to
62.5% and the 3rd to 43.75%. Spreading content across time beats batching it, and
only the strongest post per window gets full weight.

### 4.2 Out-of-network (OON) discount

Production value `OonWeightFactor = 0.75` (`vm-ranker/params.rs:242-246`).

Scope (`xai-value-model/scoring.rs:327-336`):

```rust
fn oon_applies(weights, candidate) -> bool {
    match candidate.in_network {
        Some(false) => true,                          // not followed → discount
        Some(true) => weights.oon_rescore_in_network_replies_retweets
                      && (candidate.is_reply || candidate.is_retweet),  // followed but reply/RT → also discount
        None => false,
    }
}
```

`EnableOonRescoreForInNetworkRepliesRetweets = true` (`vm-ranker/params.rs:218-222`).

**So even from accounts you follow, replies and retweets get the 0.75 discount.
Only original posts get full weight.**

Topic requests are harsher: `TopicOonWeightFactor = 0.5`
(`vm-ranker/params.rs:236-240`).

New-viewer variant: `NewUserOonWeightFactor = 0.00001` (effectively kills OON
content), but `NewUserAgeThresholdSecs = 0` → **currently disabled**
(`vm-ranker/params.rs:248-258`). Activation also requires
`viewer_following_count >= 5` (`vm-ranker/scoring/value_model.rs:21,144-146`).

### 4.3 Cold start boost — the only algorithmic assist for new accounts

Implementation: `home-mixer/scorers/author_cold_start.rs`.

**Eligibility (all must hold)**, `author_cold_start.rs:188-193` + `296-309`:

| Condition | Production threshold | Evidence |
|---|---|---|
| Must be an original post (not reply, not retweet) | hard requirement | `author_cold_start.rs:189-190` |
| Author follower count ≤ | **50,000** | `param.rs:709` |
| Post age ≤ | **7200s (2 hours)** | `param.rs:715` |
| Post's home-timeline impressions < | **200** | `param.rs:691` |
| Current position < | nonzero candidates × **0.97** | `param.rs:722` |
| Not a topic request | hard requirement | `author_cold_start.rs:384` |

**Quota: exactly ONE post is lifted per request.**

```rust
// author_cold_start.rs:216-226
let rank = rand::rng().random_range(lo..hi);   // lo=15, hi=16 → rank always 15
Some((rank, ranked[rank]))
// author_cold_start.rs:331
effective[best_idx] = effective[best_idx].max(target);
```

`ColdStartSlotMin=15`, `ColdStartSlotMax=16` (`param.rs:697,703`) → lifted to the
score of **position 16** (0-indexed 15).

**Which post wins: Thompson sampling** (`author_cold_start.rs:243-283`):

```rust
let n = scale * view_count_on_home;   // home impressions
let x = min(fav_count, n);            // likes
Beta(alpha0 + x, beta0 + (n - x)).sample()
```

`alpha0 = 0.75`, `beta0 = 49.25` (`param.rs:741,747`) → prior mean
`0.75/50 = 1.5%` like rate. Take `top_k = 2` by sampled reward
(`param.rs:753`), then pick the one with the **highest actual model score**.

**Implication**: low-impression posts get an uncertainty bonus (a test shows a
0-impression post beats a 10,000-impression 0-like post,
`author_cold_start.rs:988-1007`), but once impressions exceed 200 the post is
permanently out of the cold-start pool. **A new post's first 200 impressions are
its entire exploration budget.**

---

## 5. Where scoring actually runs (easy to misread)

The README says all three adjustments happen in `RankingScorer`. The code disagrees:

| Stage | Location | Author diversity | OON discount |
|---|---|---|---|
| home-mixer local scoring | `home-mixer/scorers/value_model.rs:46-49` | **hardcoded false** | `ctx` defaults to 1.0, no discount |
| vm-ranker recomputation | `vm-ranker/scoring/value_model.rs:109-114` | **read from params, true** | **0.75** |

home-mixer forces `compute_value_model: true` in the request
(`home-mixer/scorers/vm_ranker_request.rs:67`); vm-ranker then **recomputes** with
its own params (`vm-ranker/scoring/mod.rs:45-46`).

**The three multiplicative adjustments happen in vm-ranker, not home-mixer.**
Reading only home-mixer leads to the false conclusion that author decay is absent.

Second trap: `vm-ranker/params.rs` has **no** sync stamp at the top and its
`FavoriteWeight` default reads 0.5, while home-mixer is synced to 0.708. Both read
the **same feature-switch key** `rust_home_mixer_favorite_weight`, so production
uses one value; the repo defaults differ only because that file was not synced by
the cron. **Treat `home-mixer/params/param.rs` as authoritative.**

---

## 6. Negative-score compression: an easily missed design

```rust
// xai-value-model/scoring.rs:282-291
pub fn offset_score(combined_score, w) -> f64 {
    if combined_score < 0.0 {
        (combined_score + w.offset_negative_sum()) / total_sum * 0.001
    } else {
        combined_score + 0.001
    }
}
```

`NEGATIVE_SCORES_OFFSET = 0.001` (`weights.rs:4`).

- Net positive → add 0.001, lands in `(0.001, +∞)`
- Net negative → linearly compressed into the very narrow band `(0, 0.001)`

**Implication**: any post with a predicted net-negative score is pushed below
every net-positive post, and differences *among* negative posts are flattened
almost entirely. "How negative" barely matters — **crossing zero is effectively
a death sentence**.

---

## 7. Capabilities present but disabled (do not mistake for current behavior)

| Capability | Switch | Production value |
|---|---|---|
| Multiplicative fusion `skip × engage × time` | `ValueModelMode` | `"weighted"` (additive) `param.rs:593` |
| `not_dwelled` power penalty | `NotDwelledPowerExponent` | `0.0` → off `param.rs:581` |
| Per-viewer weight perturbation | `WeightPerturbationSigma` | `0.0` → off `vm-ranker/params.rs:191` |
| Page-level RL exploration | `EnablePageRlExploration` | `false` `param.rs:373` |
| Page decode reranking | `EnablePageDecodeRerank` | `false` `param.rs:343` |
| Near-zero OON for new viewers | `NewUserAgeThresholdSecs` | `0` → off |

If multiplicative mode were enabled the formula would become
(`scoring.rs:101-110`):

```
score = (P(not_dwelled) + offset)^exponent × (Σ positive weighted + engage_bias) × (1 + w·dwell_time)
```

i.e. probability-of-not-scrolling-past × expected engagement × duration factor,
multiplied together. **Currently not enabled.**