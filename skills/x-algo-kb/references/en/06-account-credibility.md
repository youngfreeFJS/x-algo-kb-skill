# 06 · Account Credibility and Content Classification Models

> Evidence base: `xai-org/x-algorithm` commit `a284320b66a9dce35e6f5d6b052ee308eeb12326`; paths are relative to the repo root.
> Producers: `user-cred-v2/`, `agatha/`, `bdsm/`, `grox/`, `media-model-proxy/`, `clip/`, `adult-content/`, `pnsfwmedia/`. Consumers: `botmaker-rules/`, `visibility-filtering/`, `safety-label-user-agg/`, `abuse-enforcement-service/`.
> Three classes of numbers are kept apart throughout: **verified production values** (54 / 66 / 0.95 / 0.999…), **present in code but not public or off by default** (bdsm operating points, starter-pack gate), and **sentinel or mock values** (`9.99` / `999999` / `12.34` / `12345.67`). The third class is **not** a live threshold and must never be used to explain a real penalty.

---

## 1. user-cred-v2: account weight is this one number

The output struct in `user-cred-v2/UserCredV2.scala:3-19` has only `id / mass / score`, and the mapping is hard-coded:

```
score = clamp(165.2 + 7.07 · ln(mass), 0, 100)      # score = 0 when mass <= 0
```

`ScoreSlope = 7.07` (`:10`), `ScoreIntercept = 165.2` (`:11`). **Every e-fold (≈2.718x) increase in mass adds 7.07 points; every +10 points requires mass to grow ≈4.11x.** Inverting gives `mass = exp((score − 165.2) / 7.07)` (the table below is a magnitude reference computed from that formula, not a table of repo constants):

| score | corresponding mass | use |
|---|---|---|
| 0 | ≤ 7.1e-11 | no mass / clamped |
| **54** | ≈ 1.48e-7 | `IsHighPageRankUser` exemption line (production value) |
| 55 | ≈ 1.70e-7 | VIT (very-important-tweeter) statistic line, snapshot health only |
| **66** | ≈ 8.06e-7 | grox reply-spam exemption line (production value) |
| 90 | ≈ 2.40e-5 | `gte90Count` statistic line, snapshot health only |
| 100 | ≥ 9.88e-5 | upper clamp |

**A low score triggers no penalty by itself — it is only "the absence of exemptions".** Across the whole repo there are **exactly two public numeric consumption points for the user-cred score: 54 and 66** (`botmaker-rules/scarecrow/derived-feature/HighPageRankThreshold.df:2`, `grox/flows/reply_spam/constants.py:9`); the enforcement service has a third comparison, but its threshold is a mock (§9). There is no code path of the form "low user-cred → multiply by a downranking factor": accounts below the line simply do not get "route to human review / short TTL / skip outright", and the verdicts of agatha / grox / bdsm / the media models are then **applied as-is**.

---

## 2. Where mass comes from: the only actionable part

### 2.1 Two edge types only, and no weights

| Edge type | Definition and constraints | Evidence |
|---|---|---|
| Follow edge | `FlockFollowsJavaDataset` snapshot, keeping only `stateId == 0` (`ValidState = 0`) | `UserCredV2App.scala:24-30`; `Edge.scala:11-19` |
| Engagement edge | `EngagementTypes = Set(InteractionType.Favorite, InteractionType.Retweet)` — **likes and retweets only**, no replies, clicks or dwell | `UserCredV2App.scala:79-82` |
| Engagement window | **7 days**, excluding self-engagement and `engagingUserId <= 0`; edge direction is built as `engager → post author` | `UserCredV2Config.scala:25`; `UserCredV2App.scala:84-100` |
| Edge validation | `getPageRankGraph` uses `_.asTuple.swap` for two joins: **the target must be a valid user and the source must be active** | `UserCredV2App.scala:287-318` |
| Propagation | `mass / neighbourCount`, **no edge-weight decay of any kind**; the `Edge(sourceId, destinationId)` struct has no weight field | `UserCredV2App.scala:320-390`; `Edge.scala:11-19` |

**Net effect: weight flows from the engager/follower to the engaged-with/followed account.** This is the mechanism behind "only likes/follows from high-weight accounts help"; your own actions never add mass to yourself.

### 2.2 Anti-collusion: edges between commonly controlled accounts are deleted outright

`UserCredV2App.scala:102-118` reads `AccountExpansionInvestigationsScalaDataset` (≤7 days) to obtain "linked account pairs" (alt clusters judged to be controlled by one person) and **left-joins both the follow edges and the engagement edges, dropping matched edges entirely**. **Alts following each other and alts liking each other do not exist as far as the graph is concerned.**

### 2.3 Teleport seed set: half of it is verified accounts, with no manual allowlist

`UserCredV2App.scala:141-193` `computeTeleportWeights`: `teleport = (1 − beta) · uniform + beta · engagement`, where `uniform` is spread evenly over accounts with `!isNearZero && isPremium`, and `engagement` sums each engager's normalized `engagerMass.mass × count / totalCount` per target and then normalizes globally. `beta` defaults to **0.5** and is forced into [0,1] (`UserCredV2Config.scala:35`, `:36-38`). Definition of `isPremium` (`user-cred-v2/ValidUserInfo.scala`):

```
isPremium = isBlueVerified || isGrayVerified || isGoldVerified || isVerifiedOrg || isVOAffiliate
```

**The hardest conclusion in this document: blue / gray / gold badges, verified organizations and VO affiliates directly make up half of the teleport seed set — verified accounts are the "spring" of network-wide weight.** Unverified accounts can only obtain mass indirectly, by **being liked / retweeted / followed by verified or high-mass accounts**. Buying a blue badge does not add weight directly, but it does put you on the injection side of mass.

### 2.4 Restricted accounts are absorbing states

- `restricted` / `deactivated` / `suspended` / `erased`: `ValidUserInfo.fromFlatUser` returns `None` → **excluded from the graph entirely**, neither a node nor a propagator (`user-cred-v2/ValidUserInfo.scala`).
- `userState == 1` (`NearZeroState`, near-zero): still a node, but it enters only `allUserPipe`, not `activeUserPipe` → **it can receive mass but never propagates any outward** (`UserCredV2App.scala:287-318`).

**A near-zero account is a mass black hole: likes it gives no longer transmit any weight.** Getting a pile of throttled accounts to like each other is completely ineffective on the graph.

---

## 3. Iteration, convergence and the publication gate

All defaults in `user-cred-v2/UserCredV2Config.scala:30-45`:

| Parameter | Default | Meaning |
|---|---|---|
| `jump_prob` (alpha) | **0.2** | teleport probability |
| `threshold` | **0.001** | L1 difference convergence threshold |
| `max_iterations` | **50** | maximum iteration count |
| `engagement_teleport_beta` | **0.5** | engagement / uniform mixing ratio |
| `vit_threshold` | **55.0** | VIT decision line (health statistic) |
| `gate_row_delta` / `gate_vit_delta` | 0.05 / 0.05 | relative fluctuation caps on row count / VIT count |
| `gate_mass_min` / `gate_mass_max` | **0.99 / 1.005** | total-mass conservation interval |

Iteration (`UserCredV2App.scala:320-390`): `distributed(u) = mass(u)/outDegree(u)`; `missingMass = 1 − Σdistributed` (dangling); `jumpMass(v) = p(v)·alpha + p(v)·missingMass·(1−alpha)`; `mass_new(v) = normalMass(v)·(1−alpha) + jumpMass(v)`; `diff = Σ|mass_new − mass_old|` (L1). The loop condition is `diff > 0.001 && curIteration + 1 < 50` (`:246-270`), each round is followed by normalization `mass / Σmass` (`:272-285`), and the initial value is 1.0 per valid user (`UserMass.scala:11-13`).

- **Warm start prefers the mass from the previous snapshot** (`:120-139`): this is a chain of daily incremental iterations, not a recomputation from zero each day — **neither losing weight nor recovering it happens overnight.**
- Daily schedule (`:518-534`), producing HDFS `UserCredV2ScalaDataset` + Manhattan `UserCredV2ManhattanScalaDataset`, writing `UserCredV2Scores{score, mass, snapshotTimestampMsec}` (`:453-506`).
- **Snapshot quarantine gate** (`user-cred-v2/SnapshotSafeguard.scala:21-89`): `GateMetrics(rows, massSum, vitCount = number of accounts with score ≥ 55, gte90Count = number with score ≥ 90)`, three checks `G1_row_count` / `G2_mass_sum` / `G3_vit_count`. If any is out of bounds the whole snapshot **goes to quarantine and is not published**, and serving keeps using the old scores (`UserCredV2App.scala:392-430`, unless `skip_gate` is set explicitly).

---

## 4. agatha: how other people treat your content

### 4.1 The single formula and the denominator definition

`agatha/scalding/labels/rate_based_labels/RateBasedLabels.scala:44-56` (shared by all four labels):

```
score = (interaction + 0.1) / (interaction + favs + 0.1 / prior)
```

`smoothingParam = 0.1` (`:60`), and `prior = posSum / (posSum + negSum)` is the global prior (`agatha/scalding/labels/LabelUtil.scala:41-44`). This is an **additively smoothed Bayesian ratio**, not a raw ratio — a new account with 0 likes and 0 reports does not blow up on a zero denominator. Sample size is retained explicitly (`positiveCount = interaction`, `totalCount = interaction + favs`, `:50-55`), and downstream `agatha/hub/agatha/builder/Builder.scala:27-36`, `predict/Predict.scala:27-49` feed PMI with `smoothedRatio.getOrElse(positiveCount / totalCount)`.

**The denominator uses out-of-network likes only**: `agatha/scalding/labels/favs/Favs.scala:15-68` excludes self-likes and test accounts, then anti-joins against the **mutual-follow set**, keeping only strangers' likes. **Likes from your own followers cannot dilute your report rate** — inflating likes with followers to push `ReportsPerFav` down does not work on this feature.

### 4.2 Numerators and windows of the four labels

| labelName | Numerator (interaction) | Time window | Evidence |
|---|---|---|---|
| `BlocksPerFav` | number of blocks (`stateId ∈ {0,2}`, deduplicated) | **30 days** | `RateBasedLabels.scala:81-85,120-140`; `BlocksPerFav.scala:12` |
| `ReportsPerFav` | reports via `Tool.AbuseTriageTool` | **180 days** | `RateBasedLabels.scala:65-66,86-90,142-159`; `ReportsPerFav.scala:14` |
| `SpamReportsPerFav` | spam reports with `isLegit == true` | 30 days | `RateBasedLabels.scala:67-68,91-95,161-184`; `SpamReportsPerFav.scala:14` |
| `AllSpamReportsPerFav` | all spam reports (no `isLegit` filter) | 30 days | `RateBasedLabels.scala:69-70,96-100`; `SpamReportsPerFav.scala:26` |

- **Only `ReportsPerFav` uses the long 180-day window**; the other three use 30 days (`RateBasedLabelsExtraction.scala:11`, `spam_suspended/SpamSuspendedLabelExtraction.scala:16`, `nsfw/NSFWLabelExtraction.scala:13` all set `historyDuration = Days(30)`; `agatha/scalding/RateBasedBuildJob.scala:23`, `SpagathaBuildJob.scala:21`). **A report spike from six months ago is still counting against you today.**
- Spam reports use the `TattleType` allowlist `{DirectMessageReport, ReportAsSpam, UserReport, TweetReport}` (`:161-184`); blocks require `updatedAt` inside the window and both ends passing `ArtificialUserFilter` (`:130-135`); the mention-filtered variants `MentionFilteredBlocksPerFav` / `MentionFilteredReportsPerFav` (`BlocksPerFav.scala:23`, `ReportsPerFav.scala:26`) come with 10 report engagement types (`:208-224`).
- Two further labels: `SpamSuspended` positives = suspended accounts (reason ∈ {"other","spam"}, action == "suspend", excluding notes containing `#chaq`, `agatha/scalding/util/GetSuspendedUsers.scala:14-26`); `NSFW` positives come from existing user labels `{"NsfwHighPrecision","NsfwAvatarImage","NsfwBannerImage"}` (`nsfw/NSFWLabelExtraction.scala:16-20`). Negatives are uniformly active users (`agatha/scalding/util/GetActiveUsers.scala:16-25`: not deactivated / not suspended / `userState != 1`).

### 4.3 Two caps against brigading

| Mechanism | Value | Effect | Evidence |
|---|---|---|---|
| `.distinct` dedup on (target account, actor) | — | **repeated reports/blocks by the same person against the same account count once** | `RateBasedLabels.scala:120-140,142-159,161-184` |
| `getLabelSizes(maxTakePerSourceID = 100)` + `reservoirSample(100)` | **100** | sampling grouped **by actor**: a single reporter / blocker / liker contributes at most 100 records | `LabelUtil.scala:12-23` |
| `capFeatureSum(maxFeatureSum = 1000.0)` | **1000** | per-account feature sum capped when estimating the global prior | `LabelUtil.scala:25-39` |

**A hundred people reporting you once each is far worse than one person reporting you a hundred times**: the latter is deduplicated to 1, the former is 100 independent actors; but any single actor's total contribution is then truncated at 100, so a report farm's marginal return decays quickly. **There is no "at least N likes before a verdict" threshold** — smoothing + prior + percentile calibration over active users only take its place.

### 4.4 blink score and percentile calibration

`agatha/scalding/blink/BlinkScoreJobTemplate.scala:123-128`: `blinkScore = (sumM0M1 + ln(prior)) / (sumM0 + 1)`, where `sumM0 / sumM1` are PMI moment sums over inbound / outbound features (prior at `:73-84`) — essentially a naive-Bayes-style accumulation of log priors. Then `PercentileCalibrator.calibrateDistinct` (`numPartitions=1000, k=12, reducers=500`) performs percentile calibration, and **the calibration set contains active users only** (`:184-244`).

**So the semantics of an agatha calibrated score is "your percentile among active users", in [0,1]; 0.99 means the worst 1% of active users.** There is also label-leakage exclusion (`:287-313`, e.g. `ReportsPerFav` excludes BlockGraph both directions, FavGraph inbound, AbuseReportGraph inbound, LegitTattle/NonLegitTattle both directions); **NSFW is absent** from the Manhattan import dataset (`:315-320`). The public quantile cut points (`agatha/scalding/quantile/QuantileFeatureExport.scala:27-29,44-45`): `defaultCutoffs = Seq(0.1, 0.01, 0.001, 0.0001)` (top 10%/1%/0.1%/0.01%), `keepQuantiles = Set(0.9)`, feature name `agatha.$label.$feature.$subclass.quantile_0.9_top$cutoff`. `agatha/scalding/util/FeaturesToLabels.scala:32-119` provides only the "percentile → severity" mechanism; **the actual values are not in the repo**.

### 4.5 The real decision thresholds live in botmaker, not in agatha

`botmaker-rules/scarecrow/bot/ProductionAgatha__FilterOutOrganicNotifications.bot:11-24` (bot 21278):

```
AgathaSpamSuspended > 0.99 || AgathaAllSpamReportsPerFav > 0.999 || AgathaSpamReportsPerFav > 0.999
&& !IsHighPageRankUser && !IsUserGrayVerified && !AutoExpiringTempSkipList && !HasRemediationFatigueLabel
→ SetUserLabel("AGATHA_SPAM_TOP_USER", TTL = OneWeekInSecs)   # :28-33
→ SetRemediationFatigueLabel(6 days)                          # :34
```

`botmaker-rules/scarecrow/bot/AgathaSpamProduction__ApplySearchTopTweetLabel.bot:8-27` (bot 20998): `AgathaAllSpamReportsPerFav > 0.9975 || AgathaSpamSuspended > 0.98`, likewise requiring `!IsHighPageRankUser && !IsUserGrayVerified && !SkipList` → `SetTweetRtfApplyLabelWithExpirationMs("AGATHA_SPAM", TTL = 1 week)`. The score entry point is `scarecrow/legacy/StratoRegistry.scala:137-167` `GetUserHealthScores(userId, models)` → HSS. **0.99 / 0.999 / 0.9975 / 0.98 are the only production decision thresholds on agatha scores visible anywhere in the repo.**

Account-side static features are in `agatha/scalding/data/loaders/CombinedUserDataLoader.scala:31-190` (window **Days(21)**, 9 loaders, `agatha/scalding/data/ActiveUserFeaturesJob.scala:19-42`): `email_state`, `create_week/month/year`, `created_via`, `creation_ip(/16)(/24)`, `follower_count_log / following_count_log / active_follower_count_log` (all `ceil(ln(1+v))`), `signup_country/region`, `push_device/push_client`, `profile_token`, `signup_category`, `is_verified`; restricted / frictionless / deactivated accounts are excluded. The graph feature-source enum is `agatha/hub/agatha/thrift/featureSource.thrift:3-29` (FollowGraph, FavGraph, BlockGraph, MuteGraph, AbuseReportGraph, LegitTattleGraph, NonLegitTattleNoBlocksGraph, DirectMessageGraph, CombinedUser, etc.).

---

## 5. bdsm: bot detection over behaviour sequences

### 5.1 Dimensions and inputs

`bdsm/README.md:102-103`: **256 action types / 8 classification heads / sequence length 512 / embedding width 1024** (consistent with `bdsm/runtime/manhattan_arrow_adapter.py:22-25,36`, dwell clipped to 300000 ms). The Rust extractor emits 48 `action_seq` keys (`bdsm/rust/abuse-v3-features/src/lib.rs:548-616`): `action_types` (256-dim multi-hot) + `continuous_actions` (time_delta, dwell_norm) + 31 discrete context features (`:571-601`, including `product_surface`, `client_app_id`, `had_prior_render`, `device_battery`, `device_network`, `ip_hash`, `tweet_feed_position`, `is_promoted_tweet`, `country_code`, `timezone`, etc.) + 6 derived behaviour features (`:602-607`) + 3 grouping features (`:608-610`) + 6 sequence-level statistics (`:611-616`). The model (`bdsm/runtime/model.py:11-33,62-80,239-326`) uses **time-aware RoPE** (rotary positions driven by action timestamps rather than ordinals, so "mechanical rhythm" is a native input) + GQA + RMSNorm + SwiGLU + CLS pooling + a 128-dim contrastive head; heads are 3-layer MLPs with GELU (`bdsm/runtime/task_heads.py:14-46`), and the backbone is frozen at serving time.

### 5.2 Derived features: quantified definitions of "machine smell"

`bdsm/rust/abuse-v3-features/src/derived.rs:19-77` (per action):

| Feature | Exact definition |
|---|---|
| `action_burst_count` | number of actions within ±5 sequence positions whose time difference from this action is **< 1000 ms** (the code compares time only, not action type) |
| `same_author_streak` | length of the run of consecutive actions on the same author |
| `action_transition` | `(prev × n_at + cur) % 4096`, a hash bucket for action bigrams |
| `engagement_without_impression` | a server-side action (id ∈ {1..10, 61, 62, 70}) occurring before the post was **ever rendered** (render id ∈ {11,12}) → direct API call |
| `time_since_tweet_created` | snowflake decode `(id >> 22) + 1288834974657`, then `ln_1p(minutes)/10` clipped to 1.0 |
| `dwell_to_action_ratio` | dwell duration / inter-action interval |

`derived.rs:81-148` (sequence level):

```
action_entropy          = −Σ p(action) · ln p(action)
timing_regularity       = 1 / (1 + std(Δt))            # Δt in ms; closer to 1 = more like a cron script
dwell_fraction          = count(dwell > 0) / n
unique_ips              = |distinct ip| / 100.0
sequence_time_span      = (t_max − t_min) hours / 168.0  # in units of weeks
target_tweet_repetition = max(times a single post was acted on) / n
```

**`timing_regularity` is the most direct bot probe (the smaller the interval standard deviation, the closer to 1); `engagement_without_impression` catches "liked without ever looking".** There are also 15 sequence summary counters (`manhattan_arrow_adapter.py:178,211-227`): `total`, `server_pct`, `renders`, `dwells`, `avg_dwell`, `distinct_types`, `distinct_targets`, `distinct_posts`, `follows`, `replies`, `favs`, `retweets`, `clicks`, `photo`, `client_follows`; a high `server_pct` means bypassing the client and hitting the API directly.

### 5.3 The 8 heads (`LegitimateUser` is a real eighth head)

`bdsm/runtime/heads.py:16-112`:

| index | head | selection_weight | Representative flywheel labels |
|---|---|---|---|
| 0 | `FollowBot` | 27,576 | FOLLOW_UNFOLLOW_CYCLE / PURE_FOLLOW_API_BURST / API_ONLY_BOT / GROWTH_SERVICE_BOT / FOLLOW_FARM_BOT |
| 1 | `LikeBot` | 60,320 | PURE_LIKE_API_BURST / LIKE_UNLIKE_CYCLE / STEADY_LIKE_DRIP / LIKE_FARM_BOT |
| 2 | `EngagementAmplifier` | 5,496 | LIKE_RETWEET_PAIR / FOLLOW_THEN_FAV_PIPELINE / OUTREACH_PIPELINE_BOT and 7 in total |
| 3 | `ReplySpamBot` | 8,922 | REPLY_SPAM_NO_CONSUMPTION / REPLY_SPAM_BOT / CONVERSATION_SPAMMER |
| 4 | `TweetSpamBot` | 23,425 | TWEET_CREATE_BURST / QUOTE_TWEET_SPAMMER / CONTENT_AMPLIFIER |
| 5 | `RTBot` | 5,290 | PURE_RETWEET_API_BURST / RETWEET_UNRETWEET_CYCLE |
| 6 | `MultiActionBot` | 17,474 | SCROLL_AND_LIKE / SYNTHETIC_CONSUMER / PASSIVE_SURVEILLANCE_BOT / COORDINATED_INAUTHENTIC_BOT and 9 in total |
| 7 | **`LegitimateUser`** | 0 | LEGITIMATE_ORGANIC_USER / INFREQUENT_LEGITIMATE_USER / POWER_USER_API_CLIENT / NEW_ACCOUNT_ONBOARDING / DEVELOPER_TESTING |

**`LegitimateUser` is not "1 minus the others" but an independently trained reverse head, forming the second dimension of the two-dimensional decision.** Its flywheel labels explicitly include `POWER_USER_API_CLIENT` and `DEVELOPER_TESTING` — **heavy human API users are an explicitly modeled legitimate class**. The full 0–255 action enum is in `bdsm/runtime/action_names.json`.

### 5.4 Two-dimensional decision + protective gates

Decision rule (`bdsm/runtime/score_results_sink_focal.py:836-858`): `enforcement_met ⟺ score[head] >= tau AND score[LegitimateUser] <= lambda`.

| Protection | Condition | Consequence | Evidence |
|---|---|---|---|
| Creator protection | `tweet_create_dominant >= 0.5` (share of SERVER_TWEET_CREATE) | **blocks every hard penalty** | `:836-858` |
| Unfollow-dominant | `unfollow_cnt > follow_cnt` | skip `FollowBot` | `:836-858` |
| New-account age gate | account age < **48 hours** | skip `FollowBot`; if age is unavailable, silently do not enforce (`enforcement_silenced_age_unknown`) | `:860-934,940-971`; default `:406-411` |
| login-pack gate | shown a login starter pack within **1440 minutes** | skip `FollowBot` | `:860-934`; default `:413-421` |
| starter-pack / dwell-dropout gates | `--starter-pack-gate-mode` **defaults to `off` (present in code but not enabled)**; dwell-dropout feature hit | the former switches to a challenge in `challenge` mode, the latter skips enforcement | `:422-425,890-918` |
| `ReplySpamBot` hard suspension | official client + dominant-action share ≥ **0.90** | only then is a hard suspension allowed | `:931`; default `:578-586` |
| **cusp band** | `bot >= tau − delta && legit <= lambda + delta` | **no suspension, challenge instead** (arkose / captcha / liveness) | `:981-995,187-205` |
| Too few actions | `total_actions < min_actions_for_enforcement` | only emits `enforcement_gated_low_actions` | `:972-976` |

The official client ids are **real values**: `official_client_app_ids: [3033300, 129032, 258901, 191841]` (`bdsm/runtime/sink_policy.yaml:38`). **Every operating point is a sentinel, not a production value** (`sink_policy.yaml:15-40`): `min_actions_for_enforcement: 999999` (an impossible count); in `thresholds`, FollowBot / EngagementAmplifier / RTBot = `[9.99, 9.99]`; `cusp_delta: 9.99` and `cusp_heads` EngagementAmplifier = `[9.99, 9.99]`; `paused_liveness` LikeBot / MultiActionBot = `[9.99, 9.99]`; `spam_bounce` TweetSpamBot(create) / ReplySpamBot(reply) = `[9.99, 9.99]`; `reply_spam_hard_suspend_tau: 9.99`.

`sink_policy.yaml:4-13` and `bdsm/README.md:19-40` state this explicitly: probabilities are replaced with the out-of-range sentinel `9.99` and counts with the impossible value `999999`, while production values are configured internally. **The structure, head names, action mapping and gate logic are real; not a single threshold is public** — "above what bdsm score do you get suspended" cannot be answered from this knowledge base.

### 5.5 Account-side features are zeroed in the open-source export

`lib.rs:620-626` declares 5 account features `account_age_norm`, `followers_log`, `is_verified`, **`user_cred_norm`**, `app_reputation`, but fills all of them with 0 (`lib.rs:620-626`, `manhattan_arrow_adapter.py:244-250`). **This is reverse evidence that the production model does consume the user-cred score and that the open-source version simply unplugged that input**, so the open-source export cannot reproduce live account-level decisions.

---

## 6. grox: LLM content classification

### 6.1 14 categories, 43 policyTypes

The 14 categories in `grox/flows/ptos/state.py:11-25`: `HateOrAbuse`, `ViolentSpeech`, `ChildSafety`, `NonConsensualNudity`, `IllegalAndRegulatedBehaviors`, `Spam`, `SuicideOrSelfHarm`, `AdultContent`, `ViolentMedia`, `TerrorismOrViolentExtremism`, `CivicIntegrity`, `AgeGatingHarmfulText`, `FraudAndFinancialCrime`, `LocalLawSensitiveContent`. `state.py:28-83` expands them into **43 policyTypes**:

| category | count | policyType (verbatim) |
|---|---|---|
| generic | 1 | `NoViolation` |
| ViolentMedia | 5 | `ViolentMediaGraphicMedia`, `ViolentMediaGore`, `ViolentMediaWithException`, `ViolentMediaViolentSexualConduct`, `ViolentMediaBestialityAndNecrophilia` |
| AdultContent | 2 | `AdultContentSexualHard`, `AdultContentSexualSoft` |
| IllegalAndRegulatedBehaviors | 2 | `IllegalAndRegulatedBehaviorsSexualServices`, `IllegalAndRegulatedBehaviorsIllegalDrugs` |
| HateOrAbuse | 2 | `HateOrAbuseSlursWithTarget`, `HateOrAbuseInsultsWithTarget` |
| ViolentSpeech | 6 | `ViolentSpeechMajorAndSpecificThreatWithHumanTarget`, `ViolentSpeechMajorAndNonSpecificThreatWithHumanTarget`, `ViolentSpeechMajorAndSpecificThreatWithoutHumanTarget`, `ViolentSpeechMajorAndNonSpecificThreatWithoutHumanTarget`, `ViolentSpeechMinorWithHumanTarget`, `ViolentSpeechMinorWithoutHumanTarget` |
| SuicideOrSelfHarm | 4 | `SuicideOrSelfHarmEncouraging`, `SuicideOrSelfHarmDepiction`, `SuicideOrSelfHarmEngaging`, `SuicideOrSelfHarmExpressingDesire` |
| ChildSafety | 2 | `ChildSafetySexualAbuseMaterial`, `ChildSafetySexualExploitation` |
| AgeGatingHarmfulText | 5 | `AgeGatingHarmfulTextAdultContent`, `AgeGatingHarmfulTextEatingDisorder`, `AgeGatingHarmfulTextHarmfulSubstance`, `AgeGatingHarmfulTextDangerousStunt`, `AgeGatingHarmfulTextGraphicDescription` |
| **Spam** | **14** | `SpamEngagementFarming`, `SpamEngagementTrading`, `SpamFinancialScam`, `SpamHashTagAbuse`, `SpamScamLinks`, `SpamBotProduced`, `SpamPlatformManipulation`, `SpamEngagementBaiting`, `SpamPromotesClicks`, `SpamPromotesReplies`, `SpamPromotesShares`, `SpamCardManipulation`, `SpamMentionAbuse`, `SpamManipulatedMedia` |

Five categories — `NonConsensualNudity`, `TerrorismOrViolentExtremism`, `CivicIntegrity`, `FraudAndFinancialCrime`, `LocalLawSensitiveContent` — exist in the enum but have no corresponding policyType branch.

### 6.2 No numeric cutoff; everything public is a routing threshold

`state.py:86-101`: `SafetyPolicy{policyType, confidenceScore: int|None, reason}`, `SafetyPtosViolatedPolicy{category, score: int|None, reason, safetyPolicy}`. `score` / `confidenceScore` are **integers emitted by the LLM itself**, and **the sink branches on `policyType` only and never compares their magnitudes**. **"What grox confidence counts as a violation" has no answer at the code level.** The `.j2` prompts are not public (`grox/flows/ptos/prompts.py:11-69` gives the reason: reducing the risk of being gamed, and lists 11 template names), so the decision scale of each policyType is equally unknowable. Every public number is a **routing / escalation** threshold (`grox/flows/ptos/constants.py:22-47`):

| Constant | Value | Role |
|---|---|---|
| `GEMMA` | `"oai-gemma4-26b"` | small-model slug |
| `HIGH_FAV_THRESHOLD` | **128** | likes ≥ 128 and deluxe → escalate to Grok 4.3 |
| (hard-coded) | **1024** | likes ≥ 1024 → escalate to 4.6-internal |
| `ADULT_CONTENT_LEADING_FRAMES_UNCONDITIONAL_FAV` / `MEDIA_INJECTED_REASONING_FAV` | 512 / 512 | unconditionally sample the first 10 s of video (video must be ≥ 30 s) / inject media reasoning |
| `KEY_FRAMES_UNCONDITIONAL_FAV` | 1024 | unconditional key frames |
| `MANY_MEDIA_CHUNK_SIZE` / `MANY_MEDIA_UNCONDITIONAL_FAV` | 4 / 256 | multi-image chunking |

Evidence: `grox/flows/ptos/classifier.py:627-648` (escalation branches), `:577-607` (SUPPORTED / DELUXE_4_3 / USE_REASONING / USE_GEMMA / USE_THREAD category sets), `:70-102` (circuit breaker), `:198-404` (**cross-model validation: two models disagreeing → downgrade to `NoViolation`, or downgrade to `ViolentMediaGraphicMedia`**).

**Conclusion: the more popular the content, the harder the review and the more expensive the model.** This is direct evidence that distribution volume and enforcement intensity are coupled — a viral post is not safer than a cold one; it gets re-checked repeatedly by more expensive models. Also: `task_safety_ptos_policy.py:76-86,130-174` forces posts with an NSFW history through `AdultContentSexualHard` and synthesizes `score=50` for high-like adult re-checks; `task_safety_ptos_safemodel_sex_nudity.py:22-33,79-89,123-153` uses the dedicated slug `sex-and-nudity`, **positive buckets = {"R","X"}**, 8 frames per video, at most 12 payloads per post, and discards the verdict on exception; `prior_nsfw.py:32-34` reads `safetyBoolMetadata.isNsfw`. The embedding pipeline has an additional compute gate, `grox/flows/mm_emb/adaptive_min_fav.py:7-19,54-63`: `AdaptiveMinFav(start=20_000, target_qps=5.0, gain=0.3, deadband=0.1, window_s=30.0, floor=0, cap=20_000, warmup_s=60.0)` — **when idle the threshold drops to 0 (everything is scored); when busy it rises to 20,000 likes**.

### 6.3 Reply spam: a separate 0–3 scoring path

- `grox/flows/reply_spam/classifier_reply_ranking.py:164-170`: the score must fall in the **[0,3]** rubric, out-of-range raises; `:48-51` histogram buckets `[0.0, 1.0, 2.0, 3.0]`.
- `grox/flows/reply_spam/task_write.py:140-141`: **`score == 0.0` → apply `RiskyHighVizReply`**; `:127-138` overwrites the old score only when the new one is lower (**monotonically decreasing: a reply score can only get worse**).
- Routing thresholds (`grox/flows/reply_spam/constants.py:5-9`): `GEMMA_REPLY_SPAM_MIN_FOLLOWERS = 125_000`, `GROK_GEMMA_FOLLOWER_SPLIT = 250_000`, `RISKY_HIGH_VIZ_REPLY_EXEMPT_MIN_PAGE_RANK_SCORE = ` **66**. Exemption usage in `task_write.py:39-45`: **compare against 66 when a score exists, otherwise fall back to `isHighPageRankUser`**.
- `task_filter.py:78-93`: if the replied-to account or the root-post author has > 250,000 followers → skip spam detection and go to reply_ranking; `:98,158-163` coordinated spam requires the root-post author to have ≥ **180,000** followers (the "blast radius" in the code); `:164-180` high page-rank / gray-badge accounts are skipped outright.
- The same-named label on the botmaker side: `botmaker-rules/scarecrow/bot/GroxTweetProcessor.bot` (bot 25026) `spamScore >= 0.97` → `RISKY_HIGH_VIZ_REPLY`, TTL **14 days**, skipping "the conversation author's own replies" and high-weight / gray-badge / skiplisted accounts.

**`RiskyHighVizReply` suppresses notifications only, not For You** — see §8.4.

---

## 7. Media models and "picking a point on the calibration curve"

Convention: `MMP = media-model-proxy/src/main/scala/com/twitter/media_understanding/model_proxy/model_descriptors/`.

### 7.1 Only 7 models are registered

`MMP/ModelDescriptorRegistry.scala:9-19`:

| MediaModel | Service path / timeout | Output labels | Evidence |
|---|---|---|---|
| `XxNsfw` | `/s/xx-nsfw/xx-nsfw`, 8000 ms | `nsfw.default.probability` / `.score` / `.precision` / `.recall` / `.fpr` | `MMP/XXNsfwModelDescriptor.scala:36-44,76-85` |
| `Fingerprinting` | `/s/magicpony-fingerprinting/magicpony-fingerprinting`, 3000 ms | `pixel_variance`, `embedding` (Tensor FLOAT) | `MMP/FingerprintingModelDescriptor.scala:30-35,63-65` |
| `FingerprintingV2` | same as above, 3000 ms | same as above | `MMP/FingerprintingV2ModelDescriptor.scala:30-35,63-65` |
| `ViolenceAndGore` | `/s/violence-and-gore/violence-and-gore`, 3000 ms | **not public** | `MMP/ViolenceAndGoreModelDescriptor.scala:64-69` |
| `HatefulSymbolRecognition` | `/s/magicpony-hateful/magicpony-hateful-symbol-recognition`, 3000 ms | **not public** | `MMP/HatefulSymbolRecognitionModelDescriptor.scala:45-47` |
| `CategoryClassification` | `/s/magicpony-category/magicpony-category-classification`, 3000 ms | **not public** | `MMP/CategoryClassificationModelDescriptor.scala:50-52` |
| `CategoryClassificationEmbeddings` | `/s/embeddings-category/embeddings-category-classification`, 4000 ms | **not public**, `dimensions = 256` | `MMP/CategoryClassificationEmbeddingsModelDescriptor.scala:52-60` |

`XxNsfw` supports `{TweetImage, TweetVideo, PeriscopeVideo, TweetGif}` (`XXNsfwModelDescriptor.scala:29-34`); `ViolenceAndGore` additionally covers `{AvatarImage, BannerImage}` (`ViolenceAndGoreModelDescriptor.scala:35-41`) — **avatars and banners also go through the violence model**. The Thrift enum has 20 slots (`media-model-proxy/src/main/thrift/com/twitter/cortex_media_annotator/annotate.thrift:8-29`); `XX_NSFW_V2` is defined but **not registered**, and `RESERVED_9..20` are placeholders → **production has more models than the 7 open-sourced ones**. The reason for the missing label names is located: the base class `def labels(): Map[String, Long] = Map()` defaults to empty (`MMP/ModelDescriptor.scala:25`) and those 4 models do not override it. The missing `ViolenceAndGore` thresholds can be recovered from the consumer side (`botmaker-rules/scarecrow/bot/ViolenceAndGore_ImageModel_MTT.bot:10-19,33-42`): `TWEET_IMAGE` precision > **0.6**; `TWEET_VIDEO` raw score ≥ **0.95**; `AVATAR_IMAGE` / `BANNER_IMAGE` raw score ≥ **0.85**; `:88-101` `!IsHighPageRankUser` → `TweetRtfApplyLabel("GORE_AND_VIOLENCE_HIGH_PRECISION")`, otherwise **route to human review**.

### 7.2 clip: a 256-dim shared image/text space

`clip/config.py:6,11-25`: `DEFAULT_FINAL_EMBEDDING_DIM = 256`, `input_resolution=224`, `clip_model_type="ViT-B/32"`, `logit_scale=4.5065`. The production model is `clip/keras_model.py:13-14` `PROD_MODEL = TWITTER_MODELS[0]` = **`Twitter-ViT-B/32-256`** (a 128-dim variant exists but is not live), continued training from the open-source `ViT-B/32` base (`clip/model.py:45-52`), with **L2-normalized** outputs (`clip/keras_model.py:128-130,138-140`), trained on `{tweet_text, image_byte_string}` pairs (`clip/datasets/language_image_dataset.py:29-32`). **Text preprocessing strips URLs**: `clip/utils/data_utils.py:44-53` `regex_replace(text, r"\n|\t|\r|\r\n|http\S+", "")` → **the text semantics inside the embedding contain no links**; link risk is handled by separate URL models. Image normalization uses Twitter's own means/variances (`data_utils.py:17-18`), which disagree with the export script (§9, item 15).

### 7.3 adult-content does not output a boolean but an entire curve

`adult-content/config.py:6,16-20,36`: embedding 256, Dense 128, `num_thresholds=200`; network BatchNorm → Dense(128, gelu) → Dense(1, sigmoid) (`adult-content/training.py:25-38`), metrics `PrecisionAtRecall(0.9)` + PR-AUC (`:66-76`), 50/50 rejection resampling (`adult-content/dataset_utils.py:10-12,15-23`). Calibration (`adult-content/calibration.py`): a `np.linspace(0, 1, 200)` threshold grid (`:16-20`) → per-threshold precision / recall / fpr (taking 1 when a denominator is 0, `:22-32`) → in-bucket positive rate `pos_count / total` (empty buckets take the upper bound, `:38-46`) → **isotonic regression** `IsotonicRegression(y_min=0, y_max=1, increasing=True, out_of_bounds="clip")` (`:61-69`) → outputs `thresholds_adult / precision_at_thresholds_adult / recall_at_thresholds_adult / false_positive_rate_at_thresholds_adult / probability_at_thresholds_adult` to `metrics_at_thresholds.csv` (`:78-88,97`).

**What the model delivers is the whole (threshold, precision, recall, fpr) curve; "is this porn" is decided by which point operations picks on that curve.** The production operating points are in `botmaker-rules/scarecrow/derived-feature/`:

| Derived feature | How the point is picked | Value |
|---|---|---|
| `IsHighPrecisionNsfwNewModelLogic.df:3-4` | `precisionNewNsfw >=` | **0.95** |
| `IsNearPerfectNsfwNewModelLogic.df:3-4` | `precisionNewNsfw >=` | **0.999** |
| `IsHighRecallNsfwNewModelLogic.df:3-9` | `recallNewNsfw <=`, non-video | **0.8568428** |
| same | `recallNewNsfw <=`, `category == "TWEET_VIDEO"` | **0.6** |

The directions are opposite: HighPrecision uses `precision ≥`, HighRecall uses `recall ≤` (walking along the curve toward higher recall). **The high-recall bar for video (0.6) is much looser than for images (0.857), i.e. video is more easily recalled and labeled.**

### 7.4 pnsfwmedia: the same image scores differently on different accounts

Fusion is **early-concatenation MLP**, not rule weighting. `pnsfwmedia/model_experimental.py:50-92` `_get_final_feature_tensor` **concatenates 8 feature groups**:

| # | Feature (verbatim) | Notes |
|---|---|---|
| 1 | `image_score` | frozen CLIP applied to `media.mediaunderstanding.media_embeddings.twitter_clip_as_tensor` (256-dim, `:51-53,126-128`) |
| 2 | `source_user.hss.user_health_scores.agatha_calibrated_nsfw_score` | **the account's agatha calibrated NSFW score** |
| 3 | `source_user.hss.user_health_scores.nsfw_text_user_score` | the account's text NSFW score |
| 4 | `ln(followed_by_count + 10.0)` | log follower count (`:63-69`, +10 smoothing) |
| 5 | `source_user.hss.user_health_scores.nsfw_consumer_follower_score` | **"how many of your followers are consumers of porn"** |
| 6–8 | `== -1.0` missing-indicator bits for 2/3/5 above | `:71-79` |

Network: CLIP `trainable=False` → `BatchNormalization` → `Dense(50, relu)` → `Dense(1, sigmoid)` (`:22-26,44-48`), missing default −1.0 (`:108-133`). **This is the most direct implementation of "account credibility participates in content classification": input 2 is the account's historical report/suspension percentile and input 5 is an audience profile; same image, different account or different follower composition, different output.** There are **no decision thresholds anywhere in the `pnsfwmedia` / `adult-content` Python**; all thresholds live in the `.df` files of §7.3.

### 7.5 soft-nsfw vs hard-nsfw: different consequences

`grox/flows/ptos/task_write_safety_post_annotations_result_sink.py:214-231`: `AdultContentSexualHard` → `NsfwHighRecall` (plus `NsfwHighPrecision` when media is present); `AdultContentSexualSoft` → `SoftNsfw`. Downstream (`visibility-filtering/rules/tweet_rules.rs`):

| Label | Rule | Effect |
|---|---|---|
| `NSFW_HIGH_RECALL` | `:912-917` | unconditional `drop_post(ContainNsfwMedia)` for non-authors |
| `NSFW_HIGH_PRECISION` | `:457-585` | a large family of rules: blur / interstitial / tombstone / drop depending on viewer settings, age and country |
| `SOFT_NSFW` | `:919-928` | drops for non-authors **only when `RequestHasSoftNsfwNewUserDrop && ViewerIsNewAccount`** |

**Hard applies to everyone; soft applies only to new-account viewers.** And this block at `:204-231` has **no page-rank exemption** — porn and violence do not respect account weight; only Spam / illegal / abuse / self-harm / child safety do (§8.2). At the For You layer adult/gore content is **dropped, not blurred**: blur rules are preempted by earlier drops, and blurring happens only at the Hydration (rendering) layer. User-level label propagation is in `botmaker-rules/scarecrow/bot/NsfwTweetMediaProcessor.bot:7-29` (bot 22418): `label=="3" && score>0.99` → `NSFW_NEAR_PERFECT`; `label=="3"` → `NSFW_HIGH_PRECISION`; `label=="4"` → `NSFW_HIGH_RECALL`.

---

## 8. The full closed loop: score → exemptions → labels → drops

### 8.1 Where the score lands, and the only numeric gates

`user-cred-v2/UserCredV2App.scala:453-506` writes Manhattan → `scarecrow/legacy/StratoRegistry.scala:120-135` `GetUserCredV2(userId).score` (downstream constants `scarecrow/legacy/DownstreamServices.scala:51-53`). `botmaker-rules/scarecrow/derived-feature/HighPageRankThreshold.df:2` = **54**; `IsHighPageRankUser.df:4-18`:

```
:userCredScore            = GetUserCredV2(:userId).score
:predictedHighPageRank    = Contains(:userLabels, "PREDICTED_HIGH_PAGE_RANK")
:pageRankCriteria         = Coalesce(:userCredScore, -1) >= 54 || :predictedHighPageRank
:fallbackFollowerCountCriteria = :followerCountFromGizmoduck > 25000
:usePageRankCriteria      = :userCredScore != NULL || :predictedHighPageRank
:isHighPageRankUser       = if (:usePageRankCriteria) :pageRankCriteria else :fallbackFollowerCountCriteria
```

**When no score is available it degrades to "followers > 25000".** The second numeric gate is **66** on the reply path (`grox/flows/reply_spam/constants.py:9`, usage `task_write.py:39-45`).

### 8.2 Exemptions are spread across the grox sink + ~12 bots

grox PTOS sink `:189-193`: `is_high_page_rank_user = is_high_page_rank_v2_user(author) or is_grey_badge_user(author)` (loader `grox/core/data_loaders/strato_loader.py:60-84`).

| Branch | Lines | Does it respect weight? |
|---|---|---|
| Spam default branch | `:250` | `should_label_for_spam = not is_high_page_rank_user` |
| `SpamEngagementBaiting` / `SpamEngagementFarming` / `SpamCardManipulation` / `SpamPromotesShares` | `:236-248` | **no exemption, always applies `SpamHighRecall`** |
| `NoViolation` / `SpamPromotesClicks` / `SpamPromotesReplies` | `:236-248,264-279` | **never applies a Spam label**; the latter two only apply `PromotesClicks` / `PromotesReplies` |
| Illegal and regulated behaviors | `:281-287` | `SpamHighRecall` only for non-high-weight accounts |
| `HateOrAbuseInsultsWithTarget` **and `post.language == "en"`** | `:289-299` | non-high-weight → `FosnrAbuseInsults` (**English insults only**) |
| Self-harm encouragement / depiction | `:301-315` | non-high-weight → bounce post |
| Child sexual exploitation | `:328-338` | non-high-weight → suspend user |
| ViolentMedia / AdultContent | `:204-231` | **no exemption** |

`!IsHighPageRankUser` gates on the botmaker side (line numbers): `Tweet_Search_Blacklist_RTF_All_UNSAFE_URL_Sources.bot:18`, `Tweet_Spam_High_Recall_RTF_All_Bad_URL_Sources.bot:21`, `LQ_Tweets_With_LQ_URL_Verdict_At_Mention_To_NonFollower.bot:29` and `_v2.bot:11`, `BBQDuplicateTextProd.bot:31`, `BBQDuplicateTextRepliesProd.bot:30`, `ProductionAgatha__FilterOutOrganicNotifications.bot:22`, `FollowFromActorWithPinnedLowQualityOrBadUrl.bot:31`, `AgathaSpamProduction__ApplySearchTopTweetLabel.bot:16`, `PinnedLowQualityOrBadUrl.bot:27`, `GroxTweetProcessor.bot:17`.

Special treatment for NSFW user labels (`botmaker-rules/scarecrow/derived-feature/ApplyNsfwUserLabelOrCreateReport.df:5-82`): high weight / gray badge / gold badge / skiplist → **route to human review instead of labeling directly**; even when labeled, **TTL is only 3 days** (`OneDayInSecs*3`) versus the default 7; report rate limit **1 per week**; **90-day** memory of manual removals; an extra guard `IsHighPageRankUser && NsfwConsumerFollowerScoreDouble < 0.1` (treated as a suspected false positive).

### 8.3 Post labels aggregate into account labels

`safety-label-user-agg/safetyLabelToUserLevelAggregationV2Processor.strato:31-58` reads `platform-manipulation/isHighPageRankV2` and `isGreyBadge` into `userContext.highPageRankOrGreyBadge`, then `eligibleRules = triggeredRules.filter { !isExcluded(rule, userContext) }`; `:89-106` writes via `gizmoduckSetUserLabelsColumn.put(userId, labels)` with `byUser = "Grox"`. The two default production rules in `safety-label-user-agg/postToUserLabelRules.strato:360-428`:

| rule | Triggering post labels | windowSize | minimumMatchingPosts | maxPostAgeDays | Resulting user label | TTL | Excludes high weight |
|---|---|---|---|---|---|---|---|
| `possibly_nsfw_account` | NSFW_HIGH_PRECISION / SOFT_NSFW | 10 | **11** | 60 | POSSIBLY_NSFW_ACCOUNT | 7 days | **true** |
| `nsfw_high_precision` | NSFW_HIGH_PRECISION | **5** | **3** | 60 | NSFW_HIGH_PRECISION | 7 days | false |

**`possibly_nsfw_account` can never fire under the default configuration**: the counting logic is `.take(windowSize).size >= minimumMatchingPosts` (`:266-284`), and taking 11 out of 10 is unsatisfiable (`:373-375`; the validation caps at `:96-107` allow windowSize ≤ 10, minimumMatchingPosts ≤ 11, maxPostAgeDays ≤ 60, ttl ≤ 7, mediaOnlyScanMultiplier 4). **The only rule that actually takes effect is `nsfw_high_precision`: 3 of the most recent 5 posts within 60 days judged NSFW_HIGH_PRECISION → the whole account is labeled NSFW_HIGH_PRECISION for 7 days, with no high-weight exemption.** This is the only default path by which a penalty spreads from a single post to the entire account.

### 8.4 Account labels → outright drops, and the precise meaning of "throttling"

`visibility-filtering/models/author.rs:20-37` enumerates 16 `AuthorLabel` variants, with string mapping in `visibility-filtering/hydration/decode/author.rs:199-207`. In `visibility-filtering/rules/author_rules.rs` **every rule is a `drop_post`**:

| Lines | AuthorLabel | audience | Assembly surface |
|---|---|---|---|
| `:169-174` | NsfwHighRecall | NonAuthors | For You |
| `:176-181` | NsfwHighPrecision | NonAuthors | For You |
| `:183-195` | NsfwAvatarImage / NsfwBannerImage | NonAuthors | For You |
| `:197-202` | NsfwNearPerfect | NonAuthors | For You |
| `:204-209` | SpamHighRecall | NonAuthors | For You + notifications |
| `:211-223` | Compromised / ReadOnly | NonAuthors | For You + notifications |
| `:225-230` | ImpersonationHighPrecision | NonAuthors | For You + notifications |
| `:232-237` | AbusiveHighRecall | **NonFollowers** | For You + notifications |
| `:239-244` | DoNotAmplify | **NonFollowers** | For You |
| `:246-251` | NotGraduated | **NonFollowers** | **notifications only** |
| `:253-258` | **AgathaSpamTopUser** | **NonFollowers** | **notifications only** |
| `:260-265` | EngagementSpammer | **NonFollowers** | **notifications only** |
| `:267-276` | **BlinkWorst** (+ `ViewerHasUqfEnabled` + `!ViewerHasBlinkLabel`) | **NonFollowers** | **notifications only** |
| `:278-283` | DownrankSpamReply | **NonFollowers** | **notifications only** |

The audiences must never be conflated: **`NonAuthors` = dropped for everyone except the author (followers included); `NonFollowers` = the author and followers still see it normally, only strangers lose it.** Assembly evidence (`visibility-filtering/rules/levels.rs`):

- `TIMELINE_HOME_RECOMMENDATIONS` (`:338-352`) user section = account state + block/mute + **7 NSFW-related account rules** (including 5 AuthorLabel rules) + `OON_AUTHOR_LABEL_DROPS` (`:101-108`: SpamHighRecall / Compromised / ReadOnly / ImpersonationHighPrecision / AbusiveHighRecall / DoNotAmplify). The post section (`:353-380`) additionally contains `SPAM_DROP_UNDESIRABLE`, `FOSNR_DROPS`, `AGE_GATING_DROPS`, `HOME_BLURS`, `OON_POST_DROPS` (`:215-220`: DoNotAmplify / MaliciousUrl / SpamHighRecall / BrazilElectionLegal), `FOSNR_ABUSE_INSULTS_DROP_UNDESIRABLE`.
- `TIMELINE_HOME` (the following feed, `:318-336`) user section has **only account state and block/mute, and no reputation-label rules at all**.
- SafetyLevel numbers (`visibility-filtering/rules/safety_level.rs:23-33,384-401`): `TimelineHome=8`, `FilterAll=16`, **`TimelineHomeRecommendations=61`**, `TimelineHomeHydration=82`, `TimelineHomePromotedHydration=124`, `NotificationsFollow=246`, `NotificationsWriterV2=72`.

**The precise meaning of "throttling": `drop_post` with `audience: NonFollowers` / `NonAuthors` is mounted only on `TIMELINE_HOME_RECOMMENDATIONS` (level 61); the following feed (level 8) is unaffected. It is not a downranking multiplier but a boolean revocation of recommendation eligibility — either you are in the recommendation pool or you are not.**

**A common misconception that must be corrected**: `BLINK_WORST` / `AGATHA_SPAM_TOP_USER` / `ENGAGEMENT_SPAMMER` / `NOT_GRADUATED` / `DOWNRANK_SPAM_REPLY` are mounted only in `NOTIFICATION_AUTHOR_LABEL_DROPS` (`levels.rs:132-143`), acting on `NOTIFICATIONS_FOLLOW` and `NOTIFICATIONS_WRITER_V2_*`. **Accounts in agatha's worst percentiles mainly lose notification reach, not timeline reach.** The same holds at post level: `RISKY_HIGH_VIZ_REPLY_OON_DROP_UNSPECIFIED` (`tweet_rules.rs:1029-1034`) is mounted only at `levels.rs:259` (`NOTIFICATIONS_WRITER_V2_MENTION`) and `:275` (`NOTIFICATIONS_WRITER_V2_MEDIA_TAGGED`); `SPAM_HIGH_RECALL_OON_DROP_UNDESIRABLE` (`:1022-1027`) only at `levels.rs:274`; `NOTIFICATIONS_WRITER_V2_REPLY = NOTIFICATIONS_WRITER_V2_MENTION` (`:262`); `LOW_QUALITY_AND_UQF_DROPS` (including `DOWNRANK_SPAM_REPLY_UQF_DROP_UNSPECIFIED`) and `COMMUNITY_AND_SPAM_DROPS` only at `levels.rs:253,258,292,297`.

**So grox's `RiskyHighVizReply` means "the person you replied to does not get a notification for this reply"; it does not remove the reply from For You.** What actually affects For You is a **different** post rule, `SPAM_HIGH_RECALL_DROP_UNDESIRABLE` (`tweet_rules.rs:944-949`, audience `NonAuthors`), which is mounted into level 61 via `OON_POST_DROPS`.

### 8.5 Credibility pre-check exemptions and label mapping in the enforcement service

`abuse-enforcement-service/service-lib/src/strato.rs:134-142` `compose_cred`: `is_high = is_grey_badge || is_high_page_rank_user`, carrying `score` and `follower_count` as well (struct `src/entities.rs:10-15`). In `abuse-enforcement-service/service-lib/rules/enforcement_user.yaml:19-33` two skips **precede every enforcement rule**: `high_follower_count` (`cred.follower_count >= 12.34`) and `pagerank_skipped` (`cred.is_high || cred.score >= 12.34`). **`12.34` / `12345.67` are mock values, as the YAML comments state explicitly (`:20,26`; post side `enforcement_post.yaml:24,30`); the production thresholds are not public.** The post side has the same two skips plus `&& !score.skip_author_credibility_prechecks` (`enforcement_post.yaml:23-37`) — **some models can force their way past the credibility exemption**. Label → action mapping in `enforcement_user.yaml:36-189` (main branches excerpted; there are also `anchor_campaign_user`, `spam_liveness_check_required`, `impersonation_scam_classifier_v1_suspend`, and "already labeled / already suspended → skip" dedup rules):

| score.labels | Action | TTL |
|---|---|---|
| `anchor_campaign_suspend` / `panda_reports_embedding_v10_rough_spam` / `bb1_post_spam_bot_suspend` / `bb1_reply_spam_bot_suspend` / `bb1_user_suspend` | `act_suspend_user` (perm=false, PlatformManipulation) | — |
| `anchor_campaign_suspend_cse` | `act_suspend_user` (**perm=true**, Cse) | — |
| `bb1_post_spam_bot_bounce` / `bb1_reply_spam_bot_bounce` / `bb1_user_bounce` | SpamHighRecall + `act_spam_liveness_check` | **2592000000 ms = 30 days** |
| `liveness_check_and_spam_high_recall_7d` / `spam_high_recall_7d` / `llm_slop_user` / `SpamEmbeddingMajorityPoster` | SpamHighRecall (the first also + liveness) | first three **604800000 ms = 7 days**, the last 30 days |
| `enforcement_cusp_arkose` / `_captcha` / `_liveness` (and no `enforcement_threshold_reached`) | arkose / captcha / liveness | — |
| fallback `when: "true"` | `act_suspend_user` | — |

Post side (`enforcement_post.yaml:39-76`): `llm_slop_post` → **RiskyHighVizReply** (30 days); `gibberish_post` / `fast_reply_spam_post` / `anchor_campaign_post` / `SpamEmbeddingPtosDistilled` → **SpamHighRecall** (30 days); `cse_reports_embedding_v2` → permanent suspension (Cse); the fallback `post_no_actionable_label` is a skip, not a penalty. **The loop closes**: `bb1_*` (bdsm) → `SpamHighRecall` user/post labels → `author_rules.rs:204-209` / `tweet_rules.rs:944-949` → **dropped in For You for non-authors**; whereas `llm_slop_post` → `RiskyHighVizReply` → **notifications only**.

---

## 9. Not public / does not exist / internally inconsistent (the honest list)

Types: `redacted` = deliberately removed by the release; `absent` = never existed by design; `inconsistent` = an open-source export defect that should be declared proactively when answering.

| # | Type | Item | Evidence |
|---|---|---|---|
| 1 | redacted | all grox LLM prompts `.j2` (11 template names visible, contents not) → the decision scale of each policyType is unknowable | `grox/flows/ptos/prompts.py:11-69` |
| 2 | redacted | all bdsm operating points: `[tau, lambda]`, `cusp_delta`, `reply_spam_hard_suspend_tau`, `min_actions_for_enforcement` replaced by the `9.99` / `999999` sentinels | `bdsm/runtime/sink_policy.yaml:4-13`; `bdsm/README.md:19-40` |
| 3 | redacted | the enforcement service's credibility/follower exemption thresholds: `12.34` / `12345.67` are mocks, with comments saying "Prod uses a different threshold ... to reduce gaming" | `enforcement_user.yaml:20,26`; `enforcement_post.yaml:24,30` |
| 4 | redacted | bdsm's 5 `user_features` (including `user_cred_norm`) are all zeroed in the open-source export | `lib.rs:620-626`; `manhattan_arrow_adapter.py:244-250` |
| 5 | redacted | the output label names of 4 media-model-proxy models (base class defaults to empty, not overridden) | `MMP/ModelDescriptor.scala:25` |
| 6 | redacted | the actual agatha percentile → severity values; production also unions a third, non-public population | `FeaturesToLabels.scala:32-119`; `ActiveUserFeaturesJob.scala:19-42` |
| 7 | redacted | all clip pretrained-weight URLs replaced with `https://example.invalid/...` | `clip/model.py:36-46` |
| 8 | absent | a **tier / band table** for user-cred-v2: there is only a continuous score plus two health statistic lines (55 / 90) | `SnapshotSafeguard.scala:21-89` |
| 9 | absent | **edge weights** in user-cred-v2: the struct holds only two ids | `Edge.scala:11-19` |
| 10 | absent | an agatha **"at least N likes before a verdict" threshold**: smoothing + prior + percentile calibration instead | `RateBasedLabels.scala:44-56` |
| 11 | absent | any **numeric comparison** of the LLM `score` / `confidenceScore` in the grox PTOS sink: it branches on policyType only | `state.py:86-101` + sink |
| 12 | absent | **decision thresholds** in the `pnsfwmedia` / `adult-content` Python: only calibration curves; thresholds live in the `.df` files | see §7.3 |
| 13 | inconsistent | two disagreeing `client_app_id → platform` mappings: Rust uses `258901→1, 3033300→2, 0<id<1000→4, else 0`; the Python training dialect uses `258901→1, 129032→2, 3033300→3, 0<id<1000→4`. Rust's `action_name_to_group` also omits several ids assigned by `feature_norm.py` (60, 39, 67, 64, 65, 66 and group 12) | `bdsm/rust/abuse-v3-features/src/lib.rs:188-195` vs `bdsm/runtime/feature_norm.py:52-61` |
| 14 | inconsistent | `possibly_nsfw_account` defaults to `windowSize: 10` but `minimumMatchingPosts: 11` → **never fires under the default configuration** | `postToUserLabelRules.strato:373-375` vs `:266-284` |
| 15 | inconsistent | the clip export script uses `PRETRAINED_MEANS/STDEVS` while training/validation preprocessing defaults to `TWITTER_MEANS/STDEVS` → inconsistent normalization constants | `clip/scripts/export_dbv2_image_model.py:34-35` vs `clip/utils/data_utils.py:59-60,87-88` |

**Therefore: 54 / 66 are real values on the botmaker and grox sides; the enforcement service's real values are unknown; not a single bdsm threshold is public.**

---

## 10. Three-sentence conclusion

1. **Account weight = one logarithmic PageRank score** (`clamp(165.2 + 7.07·ln(mass), 0, 100)`): half the seed set is verified accounts, engagement edges count likes and retweets only over 7 days, and edges between linked alts are deleted. It **does not downrank directly**; it only decides whether you are above or below **54** (**66** in the reply path) — above it you get "human review / short TTL / outright exemption", below it model verdicts are applied as-is.
2. **Content classification is multiple models in parallel plus picking points on calibration curves**: the porn model delivers a whole (threshold, precision, recall, fpr) curve and operations picks three strictness levels, precision ≥ 0.95 / ≥ 0.999 and recall ≤ 0.857 (video ≤ 0.6); pnsfwmedia concatenates **the account's agatha calibrated score, log follower count and the share of porn consumers among its followers** straight into the image classifier's input — **same image, different account, different result**.
3. **"Throttling" = hiding from non-followers/non-authors, and only at the recommendation layer** (level 61; the following feed at level 8 has no reputation-label rules in its user section). It is a **boolean revocation of recommendation eligibility**, not a score multiplier; account-level labels (3 of 5 posts within 60 days NSFW → account NSFW_HIGH_PRECISION for 7 days) let a penalty spread from one post to the whole account. The labels derived from the agatha / grox reply paths suppress **notifications**, not the timeline.