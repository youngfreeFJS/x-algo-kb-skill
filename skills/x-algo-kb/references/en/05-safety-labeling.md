# 05 · Safety Labeling and Enforcement: Where Labels Come From and How Long They Last

> Evidence baseline: commit `a284320b66a9dce35e6f5d6b052ee308eeb12326` (2026-11-17T03:20:50Z); all paths are relative to the repository root.
> Modules covered: `botmaker/`, `botmaker-rules/`, `scarecrow/`, `abuse-enforcement-service/`, `abuse-ledger-service/`, `safety-label-user-agg/`, `safety-label-source/`.
> Every statement is tagged with one of three states: **verified production default** / **code present but off by default** / **not public**.

---

## 1. Draw the visibility boundary first

The public rule set is **exactly countable**: **20 `.bot` files** under `botmaker-rules/scarecrow/bot/` and **53 `.df` files** under `botmaker-rules/scarecrow/derived-feature/`; there are no other `.bot`/`.df` files anywhere in the repository. Upstream explicitly admits rules are withheld: `README.md:333` — "The rules `scarecrow` loads. To reduce the risk of gaming to circumvent these systems, **some rules aren't currently in this repository**."; the withheld list at `README.md:444-447` includes "Grox prompts (j2 files)" and "Some botmaker rules". **So "I cannot find a rule for X" only licenses "the rule for X is not public" — never "X does not exist".** Every "missing" below means exactly that, not "the platform does not police this".

### 1.1 Coverage by the topics users actually ask about

| Topic | Visibility | Notes |
|---|---|---|
| spam (links / model scores) | good | rules 3226, 20789, 20998, 21278, 25026 |
| duplicate content | partial | enforcement side visible (the two BBQ rules); **the cluster similarity threshold lives in BigQuery, not in this repo**; the production rule for `DUPLICATE_CONTENT` is missing |
| bots / automation | indirect | the `bb1_*_spam_bot_*` family is visible on the abuse-enforcement side (section 6); nothing on the botmaker side |
| **coordinated manipulation** | **missing** | only the `anchor_campaign_*` label names are visible (`enforcement_user.yaml:37,40,44`); the decision logic is entirely invisible |
| **engagement farming** | **missing** | `ENGAGEMENT_SPAMMER` has a consumer only (`author_rules.rs:260`) |
| **post rate limits** | **missing** | no user posting-frequency rule at all. `RateLimited` in this repo is a gate that **protects the platform itself**, not a limit on users |
| **new-account restriction `NOT_GRADUATED`** | **missing** | consumer only (`author_rules.rs:246`); home-mixer has two additional new-account filters, but they are **off by default** (section 11.3) |
| external links | good | 6 URL rules |
| @-abuse | one rule | 5239, and it must be combined with a low-quality link |
| **hashtag abuse** | **entirely missing** | no hashtag-related enforcement rule anywhere in the repo |

### 1.2 The 14 labels that have a consumer but no producer

A reverse search across all of `botmaker-rules/` shows **zero producing rules** for the following labels, yet they are explicitly consumed in `visibility-filtering/` — **they must exist in production; only the rules are withheld**: `DUPLICATE_CONTENT`, `DUPLICATE_MENTION`, `SMYTE_SPAM_TWEET`, `DOWNRANK_SPAM_REPLY`, `ABUSIVE`, `UNTRUSTED_URL`, `ENGAGEMENT_SPAMMER`, `NOT_GRADUATED`, `RTBot`, `COMPROMISED`, `READ_ONLY`, `IMPERSONATION_HIGH_PRECISION`, `ABUSIVE_HIGH_RECALL`, `BLINK_WORST`. Consumer evidence: `visibility-filtering/rules/tweet_rules.rs:971-976` (`DUPLICATE_CONTENT`), `:985-993` (`DUPLICATE_MENTION`, requires UQF), `:995-1000` (`ABUSIVE`), `:1002-1010` (`UNTRUSTED_URL`), `:1012-1020` (`DOWNRANK_SPAM_REPLY`), `:978-983` (`SMYTE_SPAM_TWEET`); `author_rules.rs:246-251` (`NOT_GRADUATED`), `:218-223` (`READ_ONLY`), `:260-265` (`ENGAGEMENT_SPAMMER`), `:267-276` (`BLINK_WORST`).

The trap in the other direction: **`COPYPASTA_SPAM` and `SEARCH_BLACKLIST` are produced by botmaker, but nothing in `visibility-filtering/` consumes them** — they act on the search side and do not affect For You distribution.

### 1.3 Numbers that must never be quoted as production values

| Number | Source | Nature |
|---|---|---|
| `12.34` (follower count / cred score) | `enforcement_user.yaml:20,26`; `enforcement_post.yaml:24,30` | **official mock**. The comment says: "Prod uses a different follower count threshold; **this is a mock value to reduce gaming**." |
| `12345.67` (`FOLLOWER_CEILING`) | `service-lib/src/safety_checks.rs:158-162` | same, a mock |

**The real credibility / follower exemption thresholds of `abuse-enforcement-service` are not public.** The only genuine credibility gates that are public are on the botmaker side: `HighPageRankThreshold.df:2` = **54**, and on the Grox side `grox/flows/reply_spam/constants.py:9` `RISKY_HIGH_VIZ_REPLY_EXEMPT_MIN_PAGE_RANK_SCORE = 66`.

### 1.4 Three parallel chains that do not know about each other

| Chain | Input | Decision form | Cadence |
|---|---|---|---|
| `scarecrow` + `botmaker` | **events** (posting, following, changing the pinned post, URL reputation changes, model side effects…) | YAML envelope + condition/action DSL | near real time (the labeling API itself can take seconds) |
| `abuse-enforcement-service` | **`score.labels` already produced by models** | CEL-expression YAML, first match wins | request driven |
| `safety-label-user-agg` | post safety-label event stream | Strato stream aggregation, absolute counts | **deliberately delayed 10 minutes** |

All three chains can write account labels and none knows the others exist. Diagnosing "why am I being limited" requires looking at all three.

---

## 2. The rule language: the minimum you need to read one rule

### 2.1 YAML envelope + two DSL segments; `expiry` is not a TTL

`botmaker/src/thrift/com/twitter/botmaker/rule/rule.thrift:6-26` defines `BotMakerRule`: `eventType` (which event it binds to), `booleanExpression` (the condition, a boolean gate), `actionExpression` (the action, side effects), `expiryDate`, `actionLimits`. The `.bot` fields map one to one: `id` / `event` / `condition` / `action` / `expiry` / `isActive` / `actionLimits` (`GroxTweetProcessor.bot:1-2,38-40`). A `.df` is a reusable typed function supporting `params(...)`, default values, `returnType` (default `"Auto"`) and `logged` (`rule.thrift:40-48`).

**`expiry` is the retirement date of the rule itself, not the label TTL.** `BBQDuplicateTextProd.bot:75` = `2027-02-21`, `GroxTweetProcessor.bot:38` = `2029-06-14`, `ProductionAgatha__FilterOutOrganicNotifications.bot:37` = `+292278994-08-17` (i.e. never expires). Reading `expiry` as "how long the label lasts" is the single most common misreading.

### 2.2 `MATCHES` is a full-string match, not a search

`botmaker/src/java/com/twitter/botmaker/compiler/RegexCache.java:71-73`:

```java
public boolean matches(Context<?> context, String regex, String str) {
  Pattern pattern = patterns.getUnchecked(Pair.of(regex, Pattern.DOTALL)).get();
  return pattern.matcher(interruptible(context, str, timeoutMilis)).matches();
}
```

It calls Java `Matcher.matches()` (whole string), with `DOTALL`, and a **1000 ms regex timeout** (`RegexCache.java:151` `int DEFAULT_TIMEOUT_MS = 1000;`). Entry point `botmaker/src/java/com/twitter/botmaker/function/string/RegexMatch.java:45`, grammar `BotMaker.g:137-140`. **Therefore `MATCHES ".*BAD"` means "has a BAD suffix", while `MATCHES "BAD"` means strictly equal to `"BAD"`. Rule 3226 uses exactly these two tiers to separate enforcement strength: strict `"BAD"` → `SPAM`, suffixed BAD variants → `SPAM_HIGH_RECALL`** (`Tweet_Spam_High_Recall_RTF_All_Bad_URL_Sources.bot:40-46`).

Other syntax points (`botmaker/src/antlr/com/twitter/botmaker/antlr/BotMaker.g`): `TRUE`/`FALSE`/`NULL` **must be uppercase**, lowercase forms are reserved keywords (`:84-86`); backticks wrap external symbols such as `` `AutoExpiringTempSkipList` `` (`:92`); `:name` is a local variable (`:96`), `.name` a field (`:97`); `$<path/comp>.field(args)` reads a Strato column (`:190-193`); `FOREACH`/`for`/`flatmap`/`val`/`with`/`if`/`{a; b; c}` (`:201-222`); comments are `/* */` or `#` (`:80`). There are **91** event feature classes (`botmaker/scarecrow_features/src/main/java/com/twitter/scarecrow/features/`), and the 20 public rules use only 9: `bqbm_scheduled_queries` (**no corresponding feature class in the repo**), `url_event`, `url_reputation_change`, `media_update`, `tweet`, `follow`, `user_modification`, `health_side_effect`, `new_send_notification_write`, `grok_share`. Events such as `TweetCreate`/`TweetReport`/`UserCreate`/`UserReport`/`Bookmark`/`Favorite`/`Community*`/`AudioSpace*`/`DMReport`/`LoginChallengeAction`/`ArkoseVerifyEvent` **exist but no public rule uses them** — the rules in those directions are withheld.

### 2.3 Actions: use `ActionLevel` to identify real enforcement

There are **155 built-in functions** under `botmaker/src/java/com/twitter/botmaker/function/`, each annotated with an `ActionLevel`; the 8 levels are in `compiler/ActionLevel.java:3-12`. **Actions that actually change production visibility are marked `PROD_TANGIBLE_IMPACT_ACTION`** — the reliable marker for "which functions are enforcement actions".

| Action function | Write target | Key semantics | Evidence |
|---|---|---|---|
| `TweetRtfApplyLabel` | ActionIntakeService `AddLabelsV2` | `PROD_TANGIBLE_IMPACT_ACTION`; **"can take *seconds* to return"**, upstream recommends wrapping in `DoAsync`; 13 parameters including `applicableUsers` (can apply to only some of the mentioned users), `score`, `source`, `expiration` (**an absolute millisecond timestamp, NOT a TTL**), `policyKeys` | `scarecrow/function/ActionIntakeServiceRegistry.scala:21-100`, level `:30`, warning `:33-34`, params `:53-67` |
| `TweetRtfRemoveLabel` | same | removes a label | `ActionIntakeServiceRegistry.scala:102-142` |
| `SetUserLabel` | Gizmoduck | account-level label. **The 4th argument is the expiry instant**; the comment reads "expiration AT time in ms; NOTE that this is **NOT TTL** (default = now + 7 days)"; the 5th argument is force set | `scarecrow/legacy/ActionerRegistry.scala:12-39`, parameter docs `:29-39` |
| `SetLabel` / `SetLabelWithTtl` | Manhattan labelstore | **the same implementation class**; default TTL **26 hours** | `scarecrow/legacy/SpamLabelStoreRegistry.scala:106-108`, `:55` |
| `GetLabel` | same | namespace must not contain `/`; returns `""` when absent | `SpamLabelStoreRegistry.scala:17-48` |
| `CreateRtpReportAsyncProd` | human review queue | **creates a review ticket only, applies no label** | `ViolenceAndGore_ImageModel_MTT.bot:85,99` |
| `WriteUrlVerdictsV2` | URL reputation store | writes verdict + TTL + match mode | `NSFW_Card_Image_Media_To_URL_Verdict.bot:17` |

Safety check: `SetTweetRtfApplyLabelWithExpirationMs.df:2-15` only applies the label when `:expirationTimeMs > CurrentTimeMs()`; otherwise it merely records a `SetLabelWithExpiredTtl` stat.

### 2.4 Counting and rate limiting: three layers, all hard numbers

**In-rule `RateLimited`** (`scarecrow/legacy/function/RateLimited.scala:32-47`) takes `(action, lookback seconds, threshold, alias, default)`: over the threshold it runs `default`, and **with no default it throws `RateLimitedFunctionException`** (`:108-110`); the 4th argument `alias` lets several rules share one quota bucket. **Rule-level quota `ActionLimit`** (`rule.thrift:28-38`) is `{quota, periodInMinutes, strategy, version}` with `RateLimitingStrategy = TOKEN_BUCKET(0) | HALT_UNTIL_HUMAN_INTERVENTION(1)`; runtime `scarecrow/ScarecrowBotMaker.scala:450-482` (`:461` `periodSecs = periodInMinutes * 60`), decider `enable_action_rate_limiter_${appName}_$env` (`:487-496`), halted state `waitingForHumanIntervention` (`:498-506`). In Halt mode, exceeding the quota calls `setBotActionHaltedState` — **the whole bot stops and waits for a human**; the counter is named `"ActionRateLimiter_" + functionName` (`:601-603`). **`:596-598` is fail-open**: `rescue { case _ => func.apply() }` — if the limiter component dies, labels are still applied.

Underlying primitives: `AddToHLL` / `GetHLLCount` default precision **60 seconds**, default TTL **25 hours**, **hard cap 76 days** (anything beyond is truncated), cross-DC capable (`scarecrow/legacy/HllCounterStoreRegistry.scala:26-27,34,93`); `IncrementFeatureCountLite` / `GetFeatureCountLite` retain **1 day**, **read the local DC only by default**, downstream cache 1 second (`scarecrow/legacy/LimiterRegistry.scala:28-34,75-81`); `SetLabelWithTtl` defaults to **26 hours** (`SpamLabelStoreRegistry.scala:55`). Cross-DC access is wrapped in `.df`s: `AddToHLLForDataCenter.df:5-8` writes `Join(".", GetDataCenterName, :namespace)`; `GetHLLCountFromDataCenters.df:5-9` **reads both `atla.<ns>` and `pdxa.<ns>` and sums them** — this is why the NSFW account-escalation test must go through that wrapper, since a single-DC count would miss posts. Other available signals: `GetUserCredV2` (`StratoRegistry.scala:120-135`), `GetUserHealthScores(userId, List(modelNames))` (`:137-161`), `FollowerCount`/`IsFollowing` (`FlockRegistry.scala:13-34,36-61`), URL verdicts `GOOD/BAD/UNKNOWN` (`UrlVerdictRegistry.scala:67`), externally maintained lists via `GetLongList(BMSymbol)` (`scarecrow/function/ListRegistry.scala:14-26`).

---

## 3. Lookup tables for the 20 public rules

### 3.1 URL reputation (6 rules) — the largest visible family

| Rule / id | Event | Trigger condition and thresholds | Output |
|---|---|---|---|
| `Tweet_Spam_High_Recall_RTF_All_Bad_URL_Sources` / 3226 | `url_event` | `Count(redirectionChain) > 0 && GetUrlVerdictForSingleChain(...) MATCHES ".*BAD"` (`:6-7`); author is the original post author, else `tcoUserId` (`:8-24`) | **strict `"BAD"` → `SPAM`; otherwise → `SPAM_HIGH_RECALL`** (`:40-46`); `DoAsync` (`:36`) + Guano note (`:39`) |
| `Tweet_Search_Blacklist_RTF_All_UNSAFE_URL_Sources` / 20789 | `url_event` | `MATCHES ".*UNSAFE"` (`:6`) | applies **4 labels** at once, each with its own idempotency check: `SEARCH_BLACKLIST`(`:35`), `UNSAFE_URL`(`:41`), `DO_NOT_AMPLIFY`(`:47`), `MALICIOUS_URL`(`:53`) |
| `LQ_Tweets_With_LQ_URL_Verdict_At_Mention_To_NonFollower` / 5239 | `url_event` | `!isReply && !isRetweet` (`:8-9`) + verdict `MATCHES "LOW_QUALITY"` (`:22`) + **at least 1 mentioned user does not follow the author** (`:23-27`) | `SPAM_HIGH_RECALL` (`:46`) |
| same `_v2` / 6754 | `url_event` | last hop not in `Set("GOOD","WHITELIST")` (`:8`) and any URL in the chain `== "LOW_QUALITY"` (`:9`) | `SPAM_HIGH_RECALL` (`:16`); rule expiry 2028-02-08 (`:20`) |
| `rtf_tweets_on_unsafe_verdict` / 20790 | `url_reputation_change` | `verdict == "UNSAFE" && (action == "PUT" \|\| "DELETE")` (`:4-7`); `GetSlugsForUrl → GetTweetIdsForSlugs` **walks back over historical posts** (`:11-13`) | PUT applies 4 labels (`:19-22`), **DELETE removes those 4 labels** (`:24-27`) |
| `tweet_rtf_or_unrtf_on_bad_verdict` / 2002 | `url_reputation_change` | `verdict == "BAD"` + PUT/DELETE (`:4-5`); PUT re-resolves the chain and requires `Contains(:verdict,"BAD") && !Contains(...,"WHITELIST") && !Contains(...,"GOOD")` (`:13-20`) | applies / removes `SPAM` (`:31,33`) |

The 5239 gate is a single line, `Count(Filter(:victimId, !IsFollowing(GetUserIdFromScreenName(:victimId), :authorId), GetMentionedScreenNames(GetTweetText(tweetId)))) > 0` (`LQ_Tweets_With_LQ_URL_Verdict_At_Mention_To_NonFollower.bot:23-27`). **The gate is `> 0`: mentioning one single stranger counts, there is no minimum count; but a low-quality link must be present at the same time** — the production rule for pure @-harassment (no link) is not visible.

### 3.2 Account behaviour (2 rules) — guilt by pinned post

| Rule / id | Event | Condition | Output |
|---|---|---|---|
| `PinnedLowQualityOrBadUrl` / 20719 | `user_modification` | `pinnedTweetIds.simple.after` exists, is non-empty, **and differs from `.before`** (`:6-14`); after URL expansion, any verdict from `GetReputationV2(GetUrlResolutions(:urls))` is `== "BAD" \|\| == "LOW_QUALITY"` (`:15-24`) | `SetUserLabel(spammerId, "SPAM_HIGH_RECALL", "[bot/20719] PinnedLowQualityOrBadUrl", CurrentTimeMs() + OneWeekInSecs*1000)` (`:36-41`) → **account level, 7 days** |
| `FollowFromActorWithPinnedLowQualityOrBadUrl` / 20732 | `follow` | the pinned post **of the account doing the following** contains a BAD/LOW_QUALITY link (`:7-29`) | same account-level `SPAM_HIGH_RECALL`, **7 days** (`:40-45`), log text "Restricting notifications." |

### 3.3 Content models (8 rules)

| Rule / id | Event | Thresholds (verbatim numbers) | Output |
|---|---|---|---|
| `NsfwTweetMediaProcessor` / 22418 | `health_side_effect` (`subEvent == "nsfw_tweet_media"`, `:4`) | `label == "3" && score > 0.99` (`:7-12`); `label == "3"` (`:16-19`); `label == "4"` (`:23-26`) | `ApplyNsfwUserLabel` → `NSFW_NEAR_PERFECT` / `NSFW_HIGH_PRECISION` / `NSFW_HIGH_RECALL` (`:12,19,26`), **and triggers the account-level escalation test** (section 7) |
| `nsfw_user_write_user_label` / 22358 | `health_side_effect` (`nsfw_user`) | `GetUser != NULL && !IsTestUser` (`:4-6`) | `ApplyNsfwUserLabelOrCreateReport(userId, "NSFW_HIGH_PRECISION"/"NSFW_HIGH_RECALL", ...)` (`:9-10`) |
| `ViolenceAndGore_ImageModel_MTT` / 20616 | `media_update` | annotator identity `domainId == 140 && groupId == 34 && entityId == 1199070453920223232` (`:33-35`); **`TWEET_IMAGE` precision `> 0.6`** (`:10,37`); **`TWEET_VIDEO` raw_score `>= 0.95`**, **`AVATAR_IMAGE` `>= 0.85`**, **`BANNER_IMAGE` `>= 0.85`** (`:12-14,40-41`) | avatar/banner → **human ticket only**, `CreateRtpReportAsyncProd(..., "MEDIA_PROACTIVE_REVIEW", ...)` (`:83-86`); post media and not high-credibility → `TweetRtfApplyLabel("GORE_AND_VIOLENCE_HIGH_PRECISION", tweetId)` (`:88-97`); otherwise routed to humans (`:99`) |
| `AgathaSpamProduction__ApplySearchTopTweetLabel` / 20998 | `tweet` | `GetUserHealthScores(spammerId, List("AgathaAllSpamReportsPerFav","AgathaSpamSuspended"))` (`:8-14`); **`allSpamReportsPerFavScore > 0.9975 \|\| spamSuspendedScore > 0.98`** (`:14`) | `AGATHA_SPAM` post label, **TTL 7 days** (`:22-26`) |
| `NSFW_Card_Image_Media_To_URL_Verdict` / 7429 | `media_update` | `category == "CARD_IMAGE" && IsNearPerfectNsfw` (`:6-7`) | `WriteUrlVerdictsV2(Set(:cardUrlLastHop), "NSFW_CARD_IMAGE", 86400 * 7, "EXACT_URL_MATCH", ...)` (`:17`) → **URL verdict, 7 days**; revoked if no longer NSFW (`:20-27`) |
| `NSFW_Card_Image_URL_to_Tweet_Verdict` / 7413 | `url_reputation_change` | verdict `NSFW_CARD_IMAGE` + PUT/DELETE (`:7-8`) | first writes a 1-hour debounce `SetLabel("NSFW_Url", entity, "NSFW_Card_Image_Url", 1*60*60, FALSE)` (`:12`); **`:tweetSafeguard = 5000`** (`:20`) → at most **5000** not-yet-labeled posts get `NSFW_CARD_IMAGE` per run (`:22-24`); DELETE revokes (`:30-31`) |
| `NSFW_Grok_Generated_Image_To_URL_Verdict` / 24493 | `media_update` | `category == "GROK_GENERATED_IMAGE" && IsHighPrecisionNsfw` (`:6-7`) | `SetLabelWithTtl("GrokMediaNsfwDetection", entityId, "NearPerfectNsfw"\|"HighPrecisionNsfw", OneDayInSecs * 75)` (`:14-26`) → **75 days** |
| `NSFW_Grok_Share` / 24603 | `grok_share` | any grokMediaId carries a `GrokMediaNsfwDetection` label (`:7-10`); builds `https://x.com/i/grok/share/<shareId>` (`:14`) | `WriteUrlVerdictsV2(..., "NSFW_CARD_IMAGE", 86400*7, ...)` (`:18`) |

**The three NSFW tiers do not all point the same way**; the real definitions are in the `.df`s:

| Tier | Criterion | Threshold | Evidence |
|---|---|---|---|
| near-perfect | `precisionNewNsfw >=` | **0.999** | `IsNearPerfectNsfwNewModelLogic.df:3-4` |
| high-precision | `precisionNewNsfw >=` | **0.95** | `IsHighPrecisionNsfwNewModelLogic.df:3-4` |
| high-recall (non-video) | **`recallNewNsfw <=`** | **0.8568428** | `IsHighRecallNsfwNewModelLogic.df:3-9` |
| high-recall (video) | **`recallNewNsfw <=`** | **0.6** | same |

**Note the inequality is inverted for the high-recall tier: the lower the recall score, the more dangerous — the opposite of precision.** Reading `<= 0.8568428` as "only let it through if precision is below 85.7%" is wrong. The violence/gore model, meanwhile, **requires 0.95 for video but only 0.6 for images** (`ViolenceAndGore_ImageModel_MTT.bot:10,12`), so the labeling bar for images is markedly lower.

### 3.4 Bulk duplicate text (2 rules)

| Rule / id | jobName allowlist | Rate limit | Output |
|---|---|---|---|
| `BBQDuplicateTextProd` / 21711 | `bbq_duplicate_text_unigrams`, `bbq_duplicate_text_characters_cjk` (`:8-9`) | **100000 / 60s** (`:38-39`) | `COPYPASTA_SPAM` (`:46`) + a 24h dedup marker (`:47`) + 1 Guano note per user per day (`:15,55-59`) |
| `BBQDuplicateTextRepliesProd` / 21599 | `bbq_duplicate_text_unigrams_replies`, `bbq_duplicate_text_characters_replies_cjk` (`:8-9`) | **100000 / 60s** (`:37-38`) | `COPYPASTA_SPAM` (`:44`), **no Guano note** |

The dedup marker TTL defaults to **86400 seconds**: `SetBigQuerytoBotmakerLabel.df:2-3` `params(String :jobName, String :entityId, Long :ttlSecs = 86400)`, namespace `BQ_to_BM_namespace.df:2` = `"bq_to_bm_namespace"`.

---

## 4. Three rules quoted in full

### 4.1 Bulk duplicate text → `COPYPASTA_SPAM` (`BBQDuplicateTextProd.bot`, id 21711)

```yaml
id: '21711'
description:\nevent: bqbm_scheduled_queries
condition: |
  Exists(entityId) &&
  Exists(jobName) &&
  Exists(notes) &&
  (
    jobName == "bbq_duplicate_text_unigrams" ||
    jobName == "bbq_duplicate_text_characters_cjk"
  ) &&
  entityType == "tweetIdCluster"
```

Key points of the action segment (same file): `:19-22` triple dedup (already processed / already has `COPYPASTA_SPAM` / card2 is a `promo_video_convo`|`promo_image_convo` ad card); `:30-33` the four author exemptions; `:38-39` **`val :rateLimitThreshold = 1000 * 100;` `val :rateLimitTimePeriod = OneMinuteInSecs;`** → **at most 100,000 posts per 60 seconds**; `:46-47` apply the label + write the 24h dedup marker; `:55-59` write a Guano note to the author, `:15` `maxGuanoNotes = 1`; `:42-69` the whole block is wrapped in `RateLimited(..., jobName, {Log("BBQDuplicateTextProd_rate_limited", ...)})`, so **exceeding the limit only logs and drops the batch**. **`entityType == "tweetIdCluster"` shows the upstream BigQuery job has already clustered all posts site-wide by text; botmaker only labels every post in a cluster. The algorithm that decides duplication (unigram / CJK characters) lives in BigQuery, not in this repo** — "how similar counts as duplicate" is invisible; all that is visible is the enforcement-side gate of 100,000 per minute.

### 4.2 Model scores → account label + 6-day fatigue (`ProductionAgatha__FilterOutOrganicNotifications.bot:1-39`, id 21278, full text)

```yaml
id: '21278'
description:\nevent: new_send_notification_write
condition: |
  Exists(spammerId) &&
  Exists(victimId) &&
  spammerId != victimId &&
  !IsTestUser(spammerId) &&
  !HasRemediationFatigueLabel(SpammerIdString) &&
  !Contains(GetUserLabels(spammerId), "AGATHA_SPAM_TOP_USER") &&
  {
    val :scores = GetUserHealthScores(
      spammerId,
      List("AgathaSpamSuspended", "AgathaAllSpamReportsPerFav", "AgathaSpamReportsPerFav")
    );
    val :spamSuspendedScore = DictGetOrElse(:scores, "AgathaSpamSuspended", -1.0);
    val :allSpamReportsPerFavScore = DictGetOrElse(:scores, "AgathaAllSpamReportsPerFav", -1.0);
    val :spamReportsPerFavScore = DictGetOrElse(:scores, "AgathaSpamReportsPerFav", -1.0);
    :spamSuspendedScore > 0.99 ||
    :allSpamReportsPerFavScore > 0.999 ||
    :spamReportsPerFavScore > 0.999
  } &&
  !IsHighPageRankUser(spammerId) &&
  !Contains(GetLongList(`AutoExpiringTempSkipList`), spammerId) &&
  !IsUserGrayVerified(spammerId)
action: |
  {
    DoAsync({
      SetUserLabel(
        spammerId,
        "AGATHA_SPAM_TOP_USER",
        "Account identified in agatha spam models go/bot/21278",
        CurrentTimeMs() + (OneWeekInSecs * 1000)
      );
      SetRemediationFatigueLabel(SpammerIdString, OneDayInSecs * 6);
    });
  }
```

**The trigger is the moment "a notification is about to be sent to someone else", not the moment of posting.** Any **one** of the three Agatha model scores crossing its threshold is a hit: `AgathaSpamSuspended > 0.99`, `AgathaAllSpamReportsPerFav > 0.999`, `AgathaSpamReportsPerFav > 0.999` (the latter two are "reports per favourite" ratio models). It produces the account label `AGATHA_SPAM_TOP_USER` with **TTL 7 days** and simultaneously writes a **6-day fatigue marker**, so the same account cannot be re-enforced by this rule within 6 days. The fatigue namespace is isolated per rule ID: `CreateRemediationFatigueNamespace.df:2` = `Concat(RemediationFatigueLabel, "_", ToString(RULE_ID))`, constant `RemediationFatigueLabel.df:2` = `"REMEDIATION_FATIGUE_LABEL"`.

### 4.3 Grox model → risky-reply label, 14 days (`GroxTweetProcessor.bot:3-30`, id 25026)

```yaml
condition: |
  Exists(userId) &&
  Exists(spamScore) &&
  Exists(postId) &&
  healthSideEffectSubEvent == "groxScore" &&
  spamScore >= 0.97 &&
  !IsTestUser(userId)
action: |
  {
    val :tweet = GetTweetOrNull(postId);
    val :conversationId = :tweet.core_data.conversation_id;
    val :convoAuthor = GetTweetAuthorId(:conversationId);
    val :replyFromConvAuthor = (userId == :convoAuthor);
    val :highPageRankOrAutoExpiringTempSkipListOrGrayVerified = {
      IsHighPageRankUser(userId) ||
      Contains(GetLongList(`AutoExpiringTempSkipList`), userId) ||
      IsUserGrayVerified(userId)
    };
    IncrementStat("GroxProcessor/25026/AllGroxLabeled", 1);
    if (!:replyFromConvAuthor && !:highPageRankOrAutoExpiringTempSkipListOrGrayVerified) {
      SetTweetRtfApplyLabelWithExpirationMs(
        "RISKY_HIGH_VIZ_REPLY",
        postId,
        CurrentTimeMs() + (OneDayInMillis * 14)
      );
    }
```

**`spamScore >= 0.97` is the only model threshold**; there is an extra exemption for **replying to your own root post** (`:15,22`) — self-replies do not count as risky replies. The label `RISKY_HIGH_VIZ_REPLY` has **TTL 14 days**. **The surface this label actually acts on is notifications, not For You — see section 9.**

---

## 5. Counter-intuitive behavioural triggers

**Many enforcements are not evaluated "when you post"; they are triggered by a seemingly unrelated action.**

| Your action | What actually happens | Evidence |
|---|---|---|
| **changing your pinned post** | the condition explicitly compares `before`/`after` and only evaluates when the pin changes; it expands the URLs in the pinned post and checks reputation — any BAD/LOW_QUALITY → **account-level `SPAM_HIGH_RECALL`, 7 days** | `PinnedLowQualityOrBadUrl.bot:6-14,36-41` |
| **following someone** | what gets reviewed is **your own account**: your pinned post's links are checked → same account-level 7 days | `FollowFromActorWithPinnedLowQualityOrBadUrl.bot:7-29,40-45` |
| **@-mentioning one person who does not follow you + a low-quality link** | the gate is `> 0`, **one person is enough**, not a reply and not a repost → post-level `SPAM_HIGH_RECALL` | `LQ_...NonFollower.bot:8-9,23-27,46` |
| **a notification going out to someone else (your interaction triggered it)** | only at this moment do the three Agatha scores run → account `AGATHA_SPAM_TOP_USER`, 7 days | `ProductionAgatha__FilterOutOrganicNotifications.bot:2,18-20,32` |
| **deleting a link / the link being cleared** | the DELETE branch of `url_reputation_change` **retroactively removes labels from historical posts** | `rtf_tweets_on_unsafe_verdict.bot:11-13,24-27`; `tweet_rtf_or_unrtf_on_bad_verdict.bot:33` |

**A URL reputation change retroactively rewrites the labels of historical posts, and it is reversible.** This is the code basis for "the restriction lifted after I deleted the link / the link was cleared", and it is the only visible automatic label-removal path.

### 5.1 Grok-generated image → share link → reposters caught in the net

```
Grok generates an NSFW image (IsHighPrecisionNsfw)
  → 24493 writes a GrokMediaNsfwDetection label on the media, TTL 75 days
  → the user taps "share"; 24603 writes https://x.com/i/grok/share/<shareId>
     as URL verdict "NSFW_CARD_IMAGE", TTL 7 days (86400*7, EXACT_URL_MATCH)
  → 7413 receives url_reputation_change and retroactively adds the
     NSFW_CARD_IMAGE post label to up to 5000 historical posts containing that link
```

Evidence: `NSFW_Grok_Generated_Image_To_URL_Verdict.bot:6-7,14-26` → `NSFW_Grok_Share.bot:7-10,14,18` → `NSFW_Card_Image_URL_to_Tweet_Verdict.bot:7-8,20-24`. **Be precise: the verdict 24603 writes is `NSFW_CARD_IMAGE`, not `BAD`**, so it does not produce `SPAM`/`SPAM_HIGH_RECALL` via 3226 (which requires `MATCHES ".*BAD"`); the collateral landing point is the `NSFW_CARD_IMAGE` post label (consumers such as `visibility-filtering/rules/tweet_rules.rs:679-684`). **But the conclusion "whoever reposts this link gets labeled too" holds, and the media-side memory lasts 75 days.**

---

## 6. abuse-enforcement-service: enforcement tiers driven by model scores

It consumes no events; it consumes `score.labels` already produced by models and makes a **first-match** decision with CEL-expression YAML. Rust implementation; rules are compiled into the binary via `include_str!` (`service-lib/src/rules.rs:13-14`), CEL compilation at `:129`. `enforcement_user.yaml:1` states "mirrored from GrowthBook dynamic config; last sync **2026-10-20T01:49:10Z**" — **the live truth is in GrowthBook; the repo is a snapshot**.

### 6.1 Only three action classes — **no read-only**

`service-lib/src/decision.rs:1-41`: `Decision::{Skip(String), Act(Vec<ActionSpec>)}`; `ActionSpec::{SuspendUser{perm, policy}, AddLabelsV2{labels, ttl_msec}, AddPostLabelsV2{labels, ttl_msec}, Arkose, Captcha, SpamLivenessCheck}`. **All actions fall into exactly three classes: labeling / challenge verification / suspension. `READ_ONLY` exists only as a consumed author label (`author_rules.rs:218`); this service never produces it.** Dedup classes are in `decision.rs:27-40`, constants in `service-lib/src/dedup_cache.rs:11-15` (0/1/2/3/4): `CLASS_SUSPEND_PERMANENT` / `CLASS_SUSPEND` / `CLASS_CHALLENGE` (Arkose|Captcha|SpamLivenessCheck collapse into one class) / `CLASS_LABEL`. **Actions of the same class are not re-issued within a short window.** There are only two suspension policies: `types/src/action_control.rs:201-205` `SuspensionPolicy::{PlatformManipulation, Cse}` (Cse = child sexual exploitation, permanent suspension).

### 6.2 The tier ladder `suggested()` (`types/src/action_control.rs:398-416`)

| Entity | Low | Mid | High |
|---|---|---|---|
| **account** | liveness check | liveness check + `SpamHighRecall` **7 days** | **suspend** (`perm: false`, `PlatformManipulation`, `:314-317`) |
| **post** | **no action** | `SpamHighRecall` **30 days** | `SpamHighRecall` **permanent** |

`Lifetime` → milliseconds: `action_control.rs:190-192` (`Days7 = 7*86_400_000`, `Days30 = 30*86_400_000`, `Permanent = None`). The full `PageAction` set is `:276-294`. Landing mapping in `service-lib/src/action_control.rs:144-190`: `SpamHighRecall → AddLabelsV2["SpamHighRecall"]`, `PhoenixSkip → AddLabelsV2["ClientEventPhoenixSkip"]`, `PostSpamHighRecall → AddPostLabelsV2["SpamHighRecall"]`, **`HideReply → AddPostLabelsV2["RiskyHighVizReply"]`** (constant at `:142`), `SuspendAuthor → SuspendUser{perm:false, PlatformManipulation}`. Gizmoduck ordinals: `service-lib/src/gizmoduck_labels.rs:1-11` `SpamHighRecall` = **23**, `ClientEventPhoenixSkip` = **118**. The allowlist of post labels that may be applied is `action_control.rs:229-234` `PAGE_POST_LABELS = ["NsfaHighPrecision","NsfaLimitedInventory","NsfwHighPrecision","SoftNsfw"]`.

### 6.3 How Low/Mid/High is decided: a precision floor **plus a binomial test**

`types/src/action_control.rs:63-69`: `Low => 0.70`, `Mid => 0.85`, `High => 0.95`. **But those are only precision floors; a human-audit sample-size test must also pass.** `service-lib/src/confidence.rs:138-164`:

```rust
fn read_meets(reads: u32, humans: u32, floor: f64) -> bool {
    upper_tail(reads - humans, reads, floor) <= ALPHA
}
```

`ALPHA = 0.05` (`:19`), i.e. a **binomial upper-tail test**: under the hypothesis "true precision = floor", the probability of observing `reads - humans` non-human decisions must be ≤ 5%. `supported_level` (`:166-186`) takes the **highest tier** satisfying `lower_bound >= floor && read_meets(...)`. Unit tests pin the minimum sample sizes (`confidence.rs:294-312`, test name `the_memo_read_counts_meet_their_floors_and_one_fewer_does_not`):

| Target tier | floor | 0 human overturns | 1 | 2 | one fewer sample drops a tier |
|---|---|---|---|---|---|
| **High** | 0.95 | **≥ 59 reads** | ≥ 93 | ≥ 124 | `ev(0.95, 58, 0)` → only Mid |
| **Mid** | 0.85 | **≥ 19 reads** | ≥ 50 (3 overturns) | ≥ 68 (5 overturns) | `ev(0.85, 18, 0)` → only Low |
| **Low** | 0.70 | **≥ 9 reads** | — | — | `ev(0.70, 8, 0)` → **None** |

**`ev(0.99, 10, 0)`: even with a precision floor of 0.99, only 10 samples still yields Low.** `ev(0.70, 50, 25)` → None (half overturned by humans). Evidence guardrails: `confidence.rs:12-19` `DEFAULT_EVIDENCE_MAX_AGE_DAYS = 30`, `DEFAULT_FACTORY_EVIDENCE_MAX_AGE_DAYS = 365`, `CLOCK_SKEW_MS = 300_000` (5 minutes), `MAX_READS = 100_000`; `types/src/action_control.rs:153` `EVIDENCE_OVERRIDE_MAX_MS = 7 * 86_400_000` (a human evidence override expires after 7 days). Rejection conditions (`confidence.rs:166-186,193-199`): non-finite / out-of-range floor, `reads == 0`, `reads > 100k`, `humans > reads`, evidence expired or from the future. `LevelRow` mapping `confidence.rs:29-37`: `0→Missing, 1→Low, 2→Mid, 3→High`, any other value → Missing + unknown.

### 6.4 The account pipeline (`enforcement_user.yaml`, 190 lines, first match)

Up-front exemptions (skip): `:6-10` allowlist; `:12-16` `!user.present`; `:19-24` follower count (**mock**); `:26-33` cred (**mock**); `:144-148` already suspended; `:150-154` already deactivated.

| Lines | Trigger label (member of `score.labels`) | Action | TTL |
|---|---|---|---|
| `:36-38` | `anchor_campaign_suspend` | suspend `perm:false, PlatformManipulation` | — |
| `:39-41` | `anchor_campaign_user` | `AddLabelsV2 ["SpamHighRecall"]` | **no ttl = permanent** |
| `:43-45` | `anchor_campaign_suspend_cse` | suspend **`perm:true, Cse`** | permanent |
| `:47-49` / `:51-53` / `:65-67` / `:79-81` / `:177-182` | `panda_reports_embedding_v10_rough_spam` / `bb1_post_spam_bot_suspend` / `bb1_reply_spam_bot_suspend` / `bb1_user_suspend` / `impersonation_scam_classifier_v1_suspend` | suspend `perm:false` | — |
| `:55-63` / `:69-77` / `:100-108` | `bb1_post_spam_bot_bounce` / `bb1_reply_spam_bot_bounce` / `bb1_user_bounce` | `act_all`: `SpamHighRecall` + `spam_liveness_check` | **`2592000000` = 30 days** (`:62,76,107`) |
| `:83-91` | `liveness_check_and_spam_high_recall_7d` | `SpamHighRecall` + liveness | **`604800000` = 7 days** (`:90`) |
| `:93-98` | `spam_high_recall_7d` | `SpamHighRecall` | 7 days (`:98`) |
| `:112-116` / `:125-129` | `llm_slop_user` / `SpamEmbeddingMajorityPoster` **and already has** `SpamHighRecall` | **skip** (no stacking) | — |
| `:118-123` | `llm_slop_user` | `SpamHighRecall` | **7 days** (`:123`) |
| `:131-136` | `SpamEmbeddingMajorityPoster` | `SpamHighRecall` | **30 days** (`:136`) |
| `:139-142` | `spam_liveness_check_required` | liveness check | — |
| `:156-161` / `:163-168` / `:170-175` | `enforcement_cusp_arkose` / `enforcement_cusp_captcha` / `enforcement_cusp_liveness`, each && !`enforcement_threshold_reached` | **Arkose challenge / Captcha / liveness check** | — |
| **`:184-189`** | **`when: "true"` (catch-all)** | **suspend `perm:false, PlatformManipulation`** | — |

**The account pipeline's catch-all is suspension.** `rules.rs:105-120` requires a terminating `when: true` entry, otherwise `EvalError::NoMatch`. **Anything that reaches the account pipeline and is not stopped by an earlier exemption or lighter action is suspended by default.** Also note **`llm_slop_user` (AI slop) → 7 days and `SpamEmbeddingMajorityPoster` (embedding decides "the vast majority of posts are spam") → 30 days: these are the visible enforcement tiers for AI-generated content**; both have a preceding "skip if `SpamHighRecall` already present" entry, so they do not stack or extend.

### 6.5 The post pipeline (`enforcement_post.yaml`, 82 lines)

Up-front skips: `:5-21` post/author allowlists, author absent; `:23-28` follower count and `:30-37` cred (both mocks), each carrying `&& !score.skip_author_credibility_prechecks`. **`skip_author_credibility_prechecks` is a switch that can bypass the credibility exemptions**; the CEL context is defined at `rules.rs:211-237` (`ScoreCel{labels, model_version, skip_author_credibility_prechecks}`).

| Lines | Trigger | Action | TTL |
|---|---|---|---|
| `:39-44` | `llm_slop_post` | `AddPostLabelsV2 ["RiskyHighVizReply"]` | **30 days** |
| `:46-51` | `gibberish_post` | `SpamHighRecall` | 30 days |
| `:53-58` | `fast_reply_spam_post` (**instant-reply spam**) | `SpamHighRecall` | 30 days |
| `:60-62` | `anchor_campaign_post` | `SpamHighRecall` | **permanent** |
| `:65-69` | `SpamEmbeddingPtosDistilled` | `SpamHighRecall` | **permanent** |
| `:71-76` | `cse_reports_embedding_v2` | **suspend the author, `perm:true, Cse`** | permanent |
| **`:78-82`** | **`when: "true"` catch-all** | **skip (`post_no_actionable_label`)** | — |

**The key contrast: the post pipeline's catch-all is "do nothing", the account pipeline's catch-all is "suspend".** And the post side can suspend the author directly (`:71-76`, the CSE case).

### 6.6 Global guardrails

| Guardrail | Value | Evidence |
|---|---|---|
| rollout bucketing | `ROLLOUT_ALL_BP = 10_000` (basis points), FNV-1a hash | `types/src/action_control.rs:11,13-37` |
| control mode | `ControlMode::{Rules, Recording, Live, Rows}`; `Recording` is shadow mode | `:158-163` |
| forced downgrade | kill_switch / stale_snapshot / safety_checks_changed / wrong_entity / unreadable / outside_rollout all downgrade to Missing | `service-lib/src/action_control/levels.rs:202-319`, `:321-348`, `:350-400`; reason enum `confidence.rs:248-263` |
| safety precheck assertions | runtime verification that the YAML up-front skips match the code | `service-lib/src/safety_checks.rs:19-40` (USER_CHECKS), `:42-68` (POST_CHECKS), `:93-156`, `:167-175` |
| global daily volume | `WINDOW_SECS = 86_400`, `SNAPSHOT_INTERVAL_SECS = 60`, `SCAN_LIMIT = 200_000`; pkeys `global_rate_limit` / `global_rate_limit:post` | `service-lib/src/sliding_window.rs:14-18,36-38` |
| global buckets | `GLOBAL_BUCKET_USER_ID = 1`, `GLOBAL_BUCKET_POST_ID = 10`; `try_record` is **configurably fail-open** | `service-lib/src/limiter.rs:9-10,112-117` |
| **Head guard (automatic brake)** | **`DEFAULT_MIN_DECIDED_APPEALS = 30`**, **`DEFAULT_OVERTURN_WINDOW_HOURS = 72`**, `MAX_OVERTURN_WINDOW_HOURS = 168` | `types/src/head_guard.rs:7-11`, structs `:23-29,33-56` |
| other cadences | `MAX_RETRIES = 5`, `SWITCH_LISTS_POLL = 200ms`, `CONFIG_REFRESH_INTERVAL = 15s` | `service-lib/src/lib.rs:140,2904,3547` |

**Head guard semantics: if an enforcement rule's overturn rate exceeds `max_overturn_rate` across at least 30 decided appeals within a 72-hour window, the rule's actions per hour / per day are automatically throttled (`max_actions_per_hour` / `max_actions_per_day`). This is the mechanism by which "a rule with a high false-positive rate gets automatically choked off".**

---

## 7. How post labels escalate into account labels: two independent mechanisms

### 7.1 NSFW-specific: HLL counting + fatigue (botmaker side)

`botmaker-rules/scarecrow/derived-feature/ApplyNsfwUserLabel.df` (54 lines) is **the only visible complete implementation of "post labels accumulate → account label"**: `:3` namespace `"NsfwUser"`; `:5-13` three HLL topics `NSFWNearPerfectImagePosted` / `NSFWHighPrecisionImagePosted` / `NSFWHighRecallImagePosted`; `:15-17` **`:hllPrecision = 60` (seconds), `:hllTtl = 26` (hours)**, with the comment "one day + 2 hours (should match lookback sec in GetHLLCountFromDataCenters)". The core threshold at `:30-38` is `GetHLLCountFromDataCenters(:nsfwUserHllNamespace, :hllTopic, ToString(:userId), OneDayInSecs, :hllPrecision, 0, :hllSlice) > 2`. **→ a cross-DC deduplicated count > 2 within 24 hours, i.e. ≥ 3 NSFW posts, is required before escalating to an account label**; a hit records the `MoreThan2InADay` stat (`:40`). `:41-44` **enforces at most once per user per label per day**: fatigue namespace `Concat("Fatigue", RULE_ID, :label)`, `SetLabelWithTtl(..., "TRUE", DayInSecs)`; only then, at `:45`, is `ApplyNsfwUserLabelOrCreateReport` called.

### 7.2 The four-branch policy: label vs route to humans (`ApplyNsfwUserLabelOrCreateReport.df`, 93 lines)

| Branch | Condition | Result | Lines |
|---|---|---|---|
| default TTL | — | `:labelExpiry = CurrentTimeMs() + SevenDaysInSecs * 1000` = **7 days** | `:2` |
| ① recently removed by a human | `NsfwUserLabelRemoved` timestamp > `CurrentTimeMs() - (3 * ThirtyDaysInSecs * 1000)` → **a human removed an NSFW label within the past 90 days** | enters the "report instead of label" branch | `:3,7-8` |
| ② high credibility + low follower NSFW signal | `IsHighPageRankUser && NsfwConsumerFollowerScoreDouble < 0.1` | same (suspected false positive) | `:11-15` |
| ③ gray badge / skiplist / gold badge | gray-verified, `AutoExpiringTempSkipList`, gold-verified | same | `:17-19` |
| ticket rate limit | namespace `ApplyNsfwUserLabelReported` | **at most 1 ticket per user per week** (`OneWeekInSecs`) | `:22-25` |
| ticket landing | after entering the report branch it must **also** satisfy high-credibility / skiplist / gray / gold | `CreateRtpReportAsyncProd(:entity, :userId, "MEDIA_PROACTIVE_REVIEW", 2241808, :reason)`; otherwise **neither a ticket nor a label** | `:32-38`, else `:46-48` |
| ④ ordinary user | not high-credibility, not skiplisted, not gray-verified | `SetUserLabel(..., :labelExpiry)` = **7 days** | `:52-64` |
| ⑤ high credibility but not caught above | and `!GetUser(:userId).safety.nsfw_admin` | `SetUserLabel(..., CurrentTimeMs() + OneDayInSecs * 3 * 1000)` = **3 days** | `:65-72` |
| ⑥ NSFW admin | `safety.nsfw_admin == true` | **skipped entirely** | `:73-81` |

**Two forms of differential treatment are written explicitly: high-credibility accounts get NSFW labels for only 3 days while ordinary accounts get 7 (`:64` vs `:72`); accounts whose label was removed by a human within 90 days afterwards only go down the report branch and are never auto-labeled.** The latter is long-term protection after a successful appeal, lasting longer than the hold in section 8.

### 7.3 The generic aggregator: Strato stream processing, **absolute counts, not ratios**

`safety-label-user-agg/postToUserLabelRules.strato` (459 lines). Condition struct `:11-17` `PostLabelCountCondition{windowSize, minimumMatchingPosts, maxPostAgeDays, mediaOnly, postLabels}`; rule struct `:34-43` `UserLabelRule{id, enabled, triggerPostLabels, maxTriggerPostAgeDays, condition, applyUserLabel, userLabelTtlDays, exclusions}`; label selectors support DNF combinations of `anyOf`/`allOf` (`:6-9,19-25`). The decision logic (`:266-284`) boils down to `.take(condition.windowSize)` … `.size >= condition.minimumMatchingPosts`. **Take the author's most recent `windowSize` posts, count those that are "recent enough and carry the label", and escalate at ≥ `minimumMatchingPosts`. It is an absolute count, not a percentage — there is no rule like "30% of your posts labeled means suspension".** `isRecentPost` uses the Snowflake timestamp (`:77-80`); label names are normalized by stripping `_` and lowercasing (`:82-88`). With `mediaOnly` the scan volume is multiplied by 4 (`:161-174`, `mediaOnlyScanMultiplier = 4`). When several rules hit the same label, **the maximum TTL wins** (`:294-319`). Configuration guardrails (`:96-107`, validated at `:199-204,229-233,241`):

| Guardrail | Value |
|---|---|
| `allowedApplyUserLabels` | **only `POSSIBLY_NSFW_ACCOUNT` and `NSFW_HIGH_PRECISION` are allowed** |
| `maxConfiguredRules` | 10 |
| `maxConditionGroups` / `maxConditionsPerGroup` | 10 / 10 |
| `maxConfiguredWindowSize` | **10** |
| `maxConfiguredMinimumMatchingPosts` | **11** |
| `maxConfiguredPostAgeDays` | **60** |
| `maxConfiguredUserLabelTtlDays` | **7** |

**In other words: this generic aggregator can currently only produce NSFW-related account labels, looks at most at the last 10 posts, and caps account labels at 7 days. It is not a general "spam posts accumulate into a suspension" engine.** Factory default rules (`:360-428` `defaultRulesJson`):

| id | triggerPostLabels | windowSize / minimumMatchingPosts | maxPostAgeDays | applyUserLabel | userLabelTtlDays | exclusions |
|---|---|---|---|---|---|---|
| `possibly_nsfw_account` (`:364`) | `NSFW_HIGH_PRECISION` \| `SOFT_NSFW` | **10 / 11** (`:373-374`) | 60 | `POSSIBLY_NSFW_ACCOUNT` | **7** (`:387`) | nsfwUser / nsfwAdmin / highPageRankOrGreyBadge = true; already has `NSFW_HIGH_PRECISION`, `POSSIBLY_NSFW_ACCOUNT` |
| `nsfw_high_precision` (`:396`) | `NSFW_HIGH_PRECISION` | **5 / 3** (`:405-406`) | 60 | `NSFW_HIGH_PRECISION` | **7** (`:419`) | nsfwAdmin = true; already has `NSFW_HIGH_PRECISION` |

**`windowSize: 10` paired with `minimumMatchingPosts: 11` is mathematically unsatisfiable (`.take(10).size >= 11` is always false), so the factory `possibly_nsfw_account` rule can never fire.** Together with the mock comments on `12.34`/`12345.67`, this is most likely the same anti-gaming treatment (**inference, not an official statement**); the live values are overridden by a feature switch: `:430-432` `safety_understanding_post_to_user_label_rules`. **What can be confirmed as effective is the second rule: 3 of the last 5 posts carrying `NSFW_HIGH_PRECISION` → account `NSFW_HIGH_PRECISION` for 7 days.**

The executor `safetyLabelToUserLevelAggregationV2Processor.strato` (137 lines): `:19` **only handles `actionType == Applied`** (label removal does not trigger a downgrade); `:29-39` fetches the author + `platform-manipulation/isHighPageRankV2` + `isGreyBadge`; `:62-67` pages backwards through `profile/timelines/userTimeline/edgeBySource` for `maxScanSize` posts; `:68-73` reposts must resolve the original post and read `visibility/baseTweetSafetyLabelMap`; `:92-106` writes via `hmli/gizmoduckSetUserLabels` with **`byUser = "Grox"`, `source = Some("Grox")`** and `expiresAtMsec = now + ttlDays`.

---

## 8. The grace period after a successful appeal: **the number of days is unknowable**

`abuse-enforcement-service/service-lib/src/overturn_hold.rs:1-4` module text: "Overturn-hold gate: the last precheck before a suspend (or a gated label) is dispatched. It exists so we do not re-apply an enforcement that a human reviewer already overturned on appeal." Call site `service-lib/src/lib.rs:794-840` (`gated_actions`, `strip_held_labels`, skip status). The duration is entirely decided by the database; `abuse-ledger-service/src/sql.rs:3-7` verbatim:

```sql
SELECT user_id, hold_id, head, expires_at, case_group_id, reason, action_kind, label
FROM ledger.enforcement_holds
WHERE user_id = ANY($1::bigint[]) AND cleared_at IS NULL AND expires_at > now()
AND (action_kind = 'suspend' OR (action_kind = 'label' AND label = ANY($2::text[])))
```

**The duration is entirely determined by `expires_at`, a field written by an external appeal system.** Supporting evidence: `abuse-ledger-service/src/sql.rs:53-60` has a unit test asserting the service contains **no INSERT/UPDATE/DELETE/ALTER/DROP/CREATE at all** (a purely read-only service); `abuse-ledger-service/src/repo.rs:36-51` the `HoldRepo` trait only has `lookup` / `contract_check` / `ping` (plus status queries); `README.md:335` — "when an enforcement is overturned on appeal, `abuse-enforcement-service` does not re-apply that action for a fixed period, **set per appeal queue**." **Conclusion: the grace period is configured per appeal queue, not a global constant, and the specific number of days is not visible. Any claim of "you will not be limited for X days after a successful appeal" cannot be substantiated from this repository.** All that can be substantiated is that the action is skipped entirely during the hold. Visible `reason` values are `"appeal_overturned"` (`service-lib/src/ledger_contract_fixtures.rs:14`, `overturn_hold.rs:2178`) and `"manual"` (`overturn_hold.rs:418`).

Gate configuration (`overturn_hold.rs:19-47`): `CONFIG_KEY = "overturn_hold_gate"`, `LOOKUP_PATH = "/v1/holds/lookup"`, `STATUS_HOLD_OVERTURNED = "hold_overturned"`, `STATUS_HOLD_LOOKUP_FAILED = "hold_lookup_failed"`, `CONNECT_TIMEOUT = 200ms`, `MAX_BODY_BYTES = 64KiB`, **`DEFAULT_TIMEOUT_MS = 200`**, **`DEFAULT_POSITIVE_CACHE_SECS = 60`**, `MIN/MAX_TIMEOUT_MS = 10/5000`, `MAX_POSITIVE_CACHE_SECS = 3600`, **`BREAKER_FAILURES = 5`**, **`DEFAULT_BREAKER_OPEN = 10s`**, `CACHE_MAX_WEIGHT = 100_000`.

| Item | Default | Evidence |
|---|---|---|
| mode | `GateMode::{Off, Shadow, Enforce}`, **default `Off`** | `:51-56`, `:150-163` |
| lookup failure | `OnProbeError::{Allow, Skip}`, **default `Allow` (fail-open, enforce anyway)** | `:78-82`, `:150-163` |
| scope | kinds = `[Suspend]`, labels empty → **by default protects suspensions only, not labels** | `:150-163`; protecting a label requires explicitly allowlisting it, `:404-415` `gates_label(name)` |
| permanent-suspension exception | a hold only blocks when "the case-group allowlist is empty" or "`reason == \"manual\"`" or "`case_group_id` is in `perm_suspend_case_groups`" | `overturn_hold.rs` (`hold_applies`) |
| Hold struct | `{user_id, hold_id, head, expires_at, case_group_id, reason, action_kind, label}` | `:429-451`; `GateKind` constants `:102-125` |
| server-side limits | `MAX_USER_IDS = 100`, `MAX_LABELS = 32` | `abuse-ledger-service/src/api.rs:21-24` |

**Operational meaning: a successful appeal → the external system writes a hold → until `expires_at`, the same enforcement rule will not suspend you again or apply the specified label. But in the open-source snapshot this gate defaults to Off, covers suspensions only, and fails open on lookup errors.**

---

## 9. Which surface a label actually acts on

**The difference between "limited reach" and a "shadow ban" comes down to two things: the audience and the surface (level) the rule group is wired into.** `NonAuthors` = dropped for everyone except the author (**followers cannot see it either**); `NonFollowers` = visible to the author and followers, dropped only for strangers. **The two must never be conflated.** Also, a rule *defining* an audience does not mean it *takes effect* — you must check which surfaces `levels.rs` wires the rule group into.

| Label | Level | Audience / action | Rule definition | Wired surface |
|---|---|---|---|---|
| `SPAM_HIGH_RECALL` | account | **NonAuthors** → `drop_post(UnspecifiedReason)` | `author_rules.rs:204-209` | `OON_AUTHOR_LABEL_DROPS` (`levels.rs:101-108`) → **For You** (`levels.rs:351`) |
| `READ_ONLY` / `COMPROMISED` / `IMPERSONATION_HIGH_PRECISION` | account | NonAuthors | `author_rules.rs:218-223` etc. | same → **For You** |
| `DO_NOT_AMPLIFY` / `ABUSIVE_HIGH_RECALL` | account | **NonFollowers** | `author_rules.rs:239-244` | same → **For You** |
| `SPAM_HIGH_RECALL` | post | **NonAuthors** → `drop_post(PossiblyUndesirable)` | `tweet_rules.rs:944-949` | `OON_POST_DROPS` (`levels.rs:215-220`) → **For You** (`levels.rs:378`) |
| `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | post | NonFollowers → `PossiblyUndesirable` | `tweet_rules.rs:930-935,937-942` | same → **For You** |
| **`RISKY_HIGH_VIZ_REPLY`** | post | NonFollowers → `UnspecifiedReason` | `tweet_rules.rs:1029-1034` | **notifications only**: `levels.rs:259` (MENTION), `:275` (MEDIA_TAGGED). **Not wired into `TIMELINE_HOME_RECOMMENDATIONS`** |
| `DUPLICATE_CONTENT` / `DUPLICATE_MENTION` / `ABUSIVE` / `UNTRUSTED_URL` / `DOWNRANK_SPAM_REPLY` / `SMYTE_SPAM_TWEET` / `LOW_QUALITY` | post | see each rule | `tweet_rules.rs:961-1020` | `LOW_QUALITY_AND_UQF_DROPS` (`levels.rs:190-199`) → **notifications only** (`levels.rs:258,297`) |
| `NOT_GRADUATED` / `AGATHA_SPAM_TOP_USER` / `ENGAGEMENT_SPAMMER` / `BLINK_WORST` / `DOWNRANK_SPAM_REPLY` | account | NonFollowers | `author_rules.rs:246-283` | `NOTIFICATION_AUTHOR_LABEL_DROPS` (`levels.rs:132-143`) → **notifications only** (`levels.rs:238,246,270,284,310`) |
| `COPYPASTA_SPAM` / `SEARCH_BLACKLIST` | post | — | produced by botmaker | **no consumer anywhere in `visibility-filtering/`** (search side) |

**Two corrections you must remember:**

1. **Grox's `RISKY_HIGH_VIZ_REPLY` (rule 25026, `spamScore >= 0.97`, TTL 14 days) stops the person you replied to from receiving the reply notification; it does not remove the reply from For You.** Likewise `llm_slop_post` → `RiskyHighVizReply` for 30 days at `enforcement_post.yaml:39-44` is a notification-surface action.
2. **`NOT_GRADUATED`, `AGATHA_SPAM_TOP_USER` and `ENGAGEMENT_SPAMMER` only suppress notifications in the public wiring; they are not wired into For You.** Saying "a non-graduated account's content is completely invisible to non-followers" goes beyond what the public code supports — **what it supports is "notifications to non-followers are dropped"**. What actually makes an account almost fully hidden in For You is `SPAM_HIGH_RECALL` (NonAuthors).

---

## 10. Latency and TTL: the full tables, three trigger modes coexisting

| Mode | Carrier | Latency evidence |
|---|---|---|
| **event driven (near real time)** | Scarecrow consumes events, 91 event types | no explicit delay; but `ActionIntakeServiceRegistry.scala:33-34` explicitly says the labeling API **"can take *seconds* to return"**, hence most rules wrap it in `DoAsync` (`ProductionAgatha...bot:27`, `Tweet_Spam_High_Recall...bot:36`) |
| **batch (BigQuery → BotMaker)** | `bqbm_scheduled_queries`, only the two BBQ rules | the schedule lives in BigQuery and is **not visible**; what is visible is the 100,000-per-60-seconds gate per batch (`BBQDuplicateTextProd.bot:38-39`) and the 24h dedup (`SetBigQuerytoBotmakerLabel.df:2`) |
| **delayed stream aggregation** | `safety-label-user-agg` Strato forwarder | **`safetyLabelToUserLevelAggregationV2Forwarder.strato:18` `delay = 10.minutes`**; **`:19` `slo = { maxLag = 20.minutes }`**; `:5` topic `vf_tweet_safety_labels_event_prod`; `:7` consumerGroupId `safety-label-user-level-aggregation-v2`; `:15` `forwardEventsFrom = LocalZoneOnly` |

**Account-level NSFW aggregation is a batch-stream process that is "deliberately delayed 10 minutes with a 20-minute SLO ceiling", not real time.** That leaves a natural buffer window for label removal / appeals. Read-side caching determines "how soon it takes effect / how soon it disappears":

| Layer | Parameter | Value | Evidence |
|---|---|---|---|
| VF in-process hot-key cache | `TTL` | **10 seconds** | `safety-label-source/source.rs:15` |
| VF reply budget | `REPLY_ALLOWANCE` | **5 ms** | `source.rs:16` |
| expired-label handling | `label_is_live` / `drop_expired_labels` | **expired labels are filtered at read time** | `source.rs:38-57` |
| Dragonfly refresh | `REFRESH_AFTER` / `REPEAT_AFTER` | **60 s / 30 s** | `safety-label-source/dragonfly.rs:30-31` |
| Dragonfly write TTL | `WRITE_TTL_SECS` | **24 h** | `dragonfly.rs:34` |
| hit cache TTL | `found_ttl` | **24 h** (switch `rust_vf_safety_label_cache_found_ttl_secs`) | `dragonfly.rs:63,97-98` |
| **miss cache TTL** | `not_found_ttl` | **1 h** (switch `rust_vf_safety_label_cache_not_found_ttl_secs`) | `dragonfly.rs:64,99-100` |
| min TTL / queue batching | `MIN_TTL`; `REPEAT_QUEUE` / `FILL_QUEUE_KEYS` / `FILL_BATCH_KEYS` | 60 s; 500,000 / 10,000 / 100 | `dragonfly.rs:32-44` |
| backend timeout / warm-up | `request_timeout` / `connect_timeout`; `WARM_CHANNEL_CAPACITY` / `WARM_LINGER` / `WARM_FETCH_MAX_KEYS` | **20 ms / 5 s**; 1024 / **500 ms** / 50 | `safety-label-source/connect.rs:232,269`; `warmer.rs:9-11` |

**The key operational conclusion: the two TTLs point in opposite directions — do not mix them up.** `found_ttl = 24h` caches "**has** a label"; `not_found_ttl = 1h` caches "**has no** label" (`is_live` at `dragonfly.rs:248-253` picks the TTL by `Status::Found` / `NotFound`). Therefore: **a label is removed** (appeal succeeded) → the stale "has label" entry lingers, hard upper bound **24h**; **a label is added** → the stale "no label" entry lingers, hard upper bound **1h**. But these are **`is_live` hard expiry upper bounds, not guaranteed latencies**: `due_refresh` (`dragonfly.rs:160-170`) triggers **one** refresh for entries at step 0 whose age ≥ `REFRESH_AFTER` (60s) (step→1, not continuous refreshing), and `refresh_cutoff_ms` can force a refill of entries older than the cutoff. The full refresh scheduling / serving loop is not in the repository, so **the real recovery latency cannot be determined from this repo**. The 10-second hot-key TTL is the fastest path for a hot post.

Label TTL summary (all taken verbatim from code):

| Label | Level | TTL | Evidence |
|---|---|---|---|
| `AGATHA_SPAM_TOP_USER` | account | **7 days** + **6-day fatigue** | `ProductionAgatha__FilterOutOrganicNotifications.bot:32,34` |
| `SPAM_HIGH_RECALL` (pinned / follow triggered) | account | **7 days** | `PinnedLowQualityOrBadUrl.bot:40`; `FollowFromActorWithPinnedLowQualityOrBadUrl.bot:44` |
| `AGATHA_SPAM` | post | **7 days** | `AgathaSpamProduction__ApplySearchTopTweetLabel.bot:25` |
| `RISKY_HIGH_VIZ_REPLY` (Grox) | post | **14 days** | `GroxTweetProcessor.bot:29` |
| `COPYPASTA_SPAM` | post | **no TTL** (permanent; 24h dedup prevents repeats) | `BBQDuplicateTextProd.bot:46-47` |
| `SPAM` / `SPAM_HIGH_RECALL` (URL) | post | **no TTL**, revoked by the `url_reputation_change` DELETE branch | `Tweet_Spam_High_Recall...bot:41,44`; `tweet_rtf_or_unrtf_on_bad_verdict.bot:33` |
| `SEARCH_BLACKLIST` / `UNSAFE_URL` / `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | post | no TTL, revocable | `Tweet_Search_Blacklist...bot:35-53`; `rtf_tweets_on_unsafe_verdict.bot:24-27` |
| NSFW account label (ordinary) | account | **7 days** | `ApplyNsfwUserLabelOrCreateReport.df:2,64` |
| NSFW account label (high credibility) | account | **3 days** | `ApplyNsfwUserLabelOrCreateReport.df:72` |
| `POSSIBLY_NSFW_ACCOUNT` / `NSFW_HIGH_PRECISION` (aggregated) | account | **7 days** (the cap is also 7) | `postToUserLabelRules.strato:387,419,106` |
| `SpamHighRecall` (enforcement 7d tier) | account | **604800000 ms** | `enforcement_user.yaml:90,98,123` |
| `SpamHighRecall` (enforcement 30d tier) | account | **2592000000 ms** | `enforcement_user.yaml:62,76,107,136` |
| `SpamHighRecall` (anchor / embedding tiers) | account / post | **permanent (no ttl)** | `enforcement_user.yaml:39-41`; `enforcement_post.yaml:60-69` |
| `RiskyHighVizReply` (`llm_slop_post`) | post | **30 days** | `enforcement_post.yaml:39-44` |
| `GrokMediaNsfwDetection` | media | **75 days** | `NSFW_Grok_Generated_Image_To_URL_Verdict.bot:18,25` |
| `NSFW_CARD_IMAGE` URL verdict | URL | **7 days** (`86400*7`) | `NSFW_Card_Image_Media_To_URL_Verdict.bot:17`; `NSFW_Grok_Share.bot:18` |
| `NSFW_Url` debounce marker | URL | **1 hour** | `NSFW_Card_Image_URL_to_Tweet_Verdict.bot:12` |
| generic Manhattan `SetLabel` | — | **default 26 hours** | `scarecrow/legacy/SpamLabelStoreRegistry.scala:55` |
| HLL counters | — | default **25 h**, cap **76 days** | `HllCounterStoreRegistry.scala:27,34` |
| `FeatureCountLite` | — | **1 day** | `LimiterRegistry.scala:75-81` |
| BQ→BM dedup | — | **86400 s** | `SetBigQuerytoBotmakerLabel.df:2` |

Time constants (each in its own `.df:2`): `OneDayInSecs`/`DayInSecs` = 86400, `OneDayInMillis` = 86400000, `OneWeekInSecs`/`SevenDaysInSecs` = 604800, `ThirtyDaysInSecs` = 2592000, `OneMinuteInSecs` = 60.

---

## 11. Credibility exemptions and new accounts

### 11.1 `IsHighPageRankUser`: the master switch for every exemption

Key lines of `botmaker-rules/scarecrow/derived-feature/IsHighPageRankUser.df:4-18`:

```
    val :pageRankCriteria = Coalesce(:userCredScore, -1) >= HighPageRankThreshold || :predictedHighPageRank;
    val :fallbackFollowerCountCriteria = :followerCountFromGizmoduck > 25000;
    val :usePageRankCriteria = :userCredScore != NULL || :predictedHighPageRank;
```

`:predictedHighPageRank` comes from `Contains(GetUserLabels(:userId), "PREDICTED_HIGH_PAGE_RANK")` (`:12`), and `:14` decides whether the fallback is used. **`HighPageRankThreshold.df:2` = `54`** (verified production default). The test: `UserCredV2.score >= 54` **or** carrying the `PREDICTED_HIGH_PAGE_RANK` label; **only when neither is available does it fall back to `followers > 25000`**; the result is cached with `CacheGet` (`:3`). Score source `user-cred-v2/UserCredV2.scala:10-18`: `ScoreSlope = 7.07`, `ScoreIntercept = 165.2`, **`rawScore = 165.2 + 7.07 * ln(mass)`** (0 when mass ≤ 0), `score = clamp(rawScore, 0, 100)`. Solving score ≥ 54 requires `ln(mass) >= (54-165.2)/7.07 = -15.73`, i.e. mass ≥ 1.48e-7 — **an extremely low PageRank mass bar, which shows the "high credibility" decision rests mainly on the `PREDICTED_HIGH_PAGE_RANK` label rather than on the raw score**. Other exempt identities: `IsUserGrayVerified.df:4-7` = `ToLower(GetUser(:userId).safety.verified_type) == "government"` (**gray badge = government**); `IsUserGoldVerified.df:4-7` = `== "business"` (**gold badge = business**); `FollowerCountFromGizmoduck.df:4` = `GetUser(:userId).counts.followers`.

### 11.2 The four-part exemption present in every rule

The same group of conditions recurs across the 20 rules (`BBQDuplicateTextProd.bot:30-33`, `ProductionAgatha__FilterOutOrganicNotifications.bot:7,22-24`, `GroxTweetProcessor.bot:9,16-20`, `LQ_...NonFollower.bot:28-31`):

```
!IsTestUser(:author) &&
!IsHighPageRankUser(:author) &&
!Contains(GetLongList(`AutoExpiringTempSkipList`), :author) &&
!IsUserGrayVerified(:author)
```

**Read in reverse, this is the situation of an ordinary new account: high-credibility accounts, government gray badges, internal test accounts, and accounts on an externally maintained auto-expiring temporary allowlist (`AutoExpiringTempSkipList`, read via `fetcher20.getSimpleListLongValues` in `scarecrow/function/ListRegistry.scala:14-26`; the list contents are not in the repo) are systematically excluded from these labeling rules. An ordinary new account has no such protection.**

### 11.3 The two home-mixer "new account" filters: **code present, off by default; and they refer to the viewer**

**Neither filter can be used to explain any real reach problem**, for two independent reasons. **(a) Both switches default to false:** `EnableNewUserMinEngagementFilter` (`rust_home_mixer_enable_new_user_min_engagement_filter`) = **`false`** (`home-mixer/params/param.rs:937-941`); `EnableNewUserSoftNsfwFilter` (`rust_home_mixer_enable_new_user_soft_nsfw_filter`) = **`false`** (`param.rs:967-971`). **(b) The "new user" in `NewUserMinEngagementFilter` is the viewer (`query.user_id`), not the author:**

```rust
// home-mixer/filters/new_user_min_engagement_filter.rs:70-77
fn within_account_age(query: &ScoredPostsQuery) -> bool {
    let max_age_secs = query.params.get(NewUserMinEngagementFilterMaxAccountAgeSecs);
    duration_since_creation_opt(query.user_id)   // query.user_id = the VIEWER
        .map(|age| age < Duration::from_secs(max_age_secs))
        .unwrap_or(false)
}
```

**Even if enabled, it limits "how much strangers' content a freshly registered viewer can see", not "how much distribution a new author can get".** The OON-only scope is real: `should_keep` returns true immediately when `candidate.in_network != Some(false)` (`new_user_min_engagement_filter.rs:60-63`). The thresholds themselves are genuine defaults, but **because the switches are off, none of them take effect**:

| Parameter | Default | State | Evidence |
|---|---|---|---|
| `NewUserMinEngagementFilterMetric` / `NewUserMinEngagementFilterUseRatio` | `"fav"` / `true` (divide by impressions) | code present, off by default | `param.rs:946`, `:952` (switch name `:951`) |
| `NewUserMinEngagementThreshold` | `0.004` | same | `param.rs:955-958` |
| `NewUserMinEngagementFilterMaxAccountAgeSecs` / `NewUserMinEngagementFilterMaxResurrectionAgeSecs` | `1800` (30 minutes) / `1800` | same | `param.rs:961-964`, `:985-988` |
| `NewUserSoftNsfwFilterMaxAccountAgeSecs` / `NewUserSoftNsfwFilterMaxScoringSeqLength` | `604800` (7 days) / `100` | same | `param.rs:973-976`, `:979-982` |

The second filter's logic (`home-mixer/filters/new_user_soft_nsfw_filter.rs:13-27`): For You non-topic surfaces only + account age < 7 days + scoring sequence length < 100; `:38-40,52` removes out-of-network posts with `soft_nsfw == true`. **Also off by default.** Metric definitions for reference: `:92-104` fav/engagement/view, optionally divided by impressions to form a ratio; `:106-113` engagement = fav + reply + repost + quote.

### 11.4 `NOT_GRADUATED`

`visibility-filtering/rules/author_rules.rs:246-251`: `NOT_GRADUATED_USER_LABEL_DROP_UNSPECIFIED`, audience **NonFollowers**, `AuthorHasLabel(AuthorLabel::NotGraduated)` → `drop_post(DropAs::UnspecifiedReason)`. **The rule that produces this label is not public** (section 1.2), **and in the public wiring it acts on the notification surface only** (section 9). "How long after registration counts as graduated" is entirely invisible.

---

## 12. Hard conclusions you can quote directly

1. **Labeling is "model score + hard threshold", not a fuzzy holistic judgement**: Grox `spamScore >= 0.97` (`GroxTweetProcessor.bot:8`), Agatha `> 0.99 / 0.999 / 0.999` (`ProductionAgatha...bot:18-20`), NSFW near-perfect `>= 0.999` (`IsNearPerfectNsfwNewModelLogic.df:3`), gore images `> 0.6` / video `>= 0.95` (`ViolenceAndGore_ImageModel_MTT.bot:10,12`).
2. **`MATCHES` is a full-string match** (`RegexCache.java:71-73`); `".*BAD"` and `"BAD"` are two different strength tiers producing `SPAM_HIGH_RECALL` and `SPAM` respectively (`Tweet_Spam_High_Recall...bot:40-46`).
3. **URL reputation changes retroactively rewrite historical post labels, and are reversible** (`rtf_tweets_on_unsafe_verdict.bot:11-13,24-27`).
4. **Changing your pinned post triggers a whole-account re-check and can cause an account-level 7-day restriction** (`PinnedLowQualityOrBadUrl.bot:6-14,36-41`); **following someone also triggers a review of yourself** (`FollowFromActorWithPinnedLowQualityOrBadUrl.bot:7-29,40-45`).
5. **@-mentioning a stranger + a low-quality link = restriction, and the threshold is 1 person** (`LQ_...NonFollower.bot:23-27,46`); the pure @-harassment rule is not visible.
6. **Account-level aggregation is "an absolute M out of the last N", not a ratio**; the generic aggregator may only produce NSFW-type account labels, window ≤ 10, TTL ≤ 7 days (`postToUserLabelRules.strato:96-107,266-284`). The effective default is **3 of 5** (`:405-406`); the other rule, **10/11, can mathematically never fire** (`:373-374`).
7. **NSFW escalation to an account label needs ≥ 3 cross-DC posts within 24h** (`ApplyNsfwUserLabel.df:30-38`), at most one enforcement per user per label per day (`:41-44`); high-credibility accounts 3 days, ordinary accounts 7 days (`ApplyNsfwUserLabelOrCreateReport.df:64,72`).
8. **There are only three enforcement classes: labeling / challenge verification (Arkose, Captcha, liveness) / suspension — no read-only action** (`decision.rs:1-41`). The account pipeline's catch-all is suspension (`enforcement_user.yaml:184-189`), the post pipeline's catch-all is no action (`enforcement_post.yaml:78-82`).
9. **The High tier requires a precision floor ≥ 0.95 and ≥ 59 human audit reads with 0 overturns** (`action_control.rs:65-67` + `confidence.rs:162-163,296`); insufficient samples automatically downgrade, and `ev(0.99,10,0)` only qualifies for Low.
10. **Both home-mixer "new account" filters are off by default, and the "new user" in `NewUserMinEngagementFilter` means the viewer, not the author** (`param.rs:937-941,967-971` + `new_user_min_engagement_filter.rs:70-77`). **Do not use them to explain a new account getting no impressions.** What is systematically exempted is high credibility (cred ≥ 54 or `PREDICTED_HIGH_PAGE_RANK`, falling back to followers > 25000 when no score), government gray badges, and temporary-allowlist accounts (`IsHighPageRankUser.df:4-18`, `HighPageRankThreshold.df:2`).
11. **`RISKY_HIGH_VIZ_REPLY` suppresses notifications, not For You distribution** (`levels.rs:259,275`; not wired into `TIMELINE_HOME_RECOMMENDATIONS`).
12. **The appeal grace period exists but its length is unknowable**, and the gate defaults to Off, protects suspensions only, and fails open on lookup errors (`overturn_hold.rs:150-163`, `README.md:335`, `abuse-ledger-service/src/sql.rs:3-7`).
13. **Visibility recovery after label removal has cache lag, and the direction is easy to get backwards**: `Found` (has label) entries have a 24h TTL, `NotFound` (no label) 1h (`dragonfly.rs:63-64,248-253`); there is also a **one-shot** refresh at `REFRESH_AFTER=60s` (`:160-170`). 24h/1h are hard upper bounds, not guaranteed latencies; the real recovery latency cannot be determined from this repo.

**Three unknowns that must always be flagged**: ① the exact number of days in the appeal grace period (DB `expires_at`, configured per appeal queue); ② the follower / PageRank exemption thresholds of `abuse-enforcement-service` (`12.34` and `12345.67` are official mocks); ③ the decision logic for coordinated manipulation, engagement farming, posting rate, hashtag abuse and `NOT_GRADUATED` (`README.md:333,444-447` admits these are withheld).