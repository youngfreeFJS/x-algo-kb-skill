# 04 · Visibility Filtering: Whether a Post Can Be Shown At All

> Evidence base: `xai-org/x-algorithm` @ `a284320b66a9dce35e6f5d6b052ee308eeb12326`, verified line by line, read-only.
> Path abbreviations (relative to the repo root): `tweet_rules.rs` / `author_rules.rs` / `levels.rs` / `engine.rs` / `action_kind.rs` / `safety_level.rs` / `catalog.rs` / `fixtures.rs` / `defaults.rs` / `experiment.rs` / `rule_spec.rs` = `visibility-filtering/rules/<file>`; `rule_spec/<file>` = `visibility-filtering/rules/rule_spec/<file>`; `golden_corpus/<file>` = `visibility-filtering/rules/golden_corpus/<file>`.
> `verdict.rs` / `viewer.rs` / `tweet.rs` / `author.rs` / `region.rs` / `safety_labels.rs` / `mod.rs` = `visibility-filtering/models/<file>`; `proto.rs` / `thrift.rs` / `rpc.rs` = `visibility-filtering/treatment/<file>`.
> `params.rs` = `visibility-filtering/params.rs`; `client_switches.rs` / `limited_actions_policy.rs` / `limited_actions_copy.rs` = `visibility-filtering/params/<file>`.

**This subsystem only decides "can it be shown, and in what form". It does not score and it does not downrank.** The weight formula lives in `02-scoring-ranking` (`xai-value-model` / `vm-ranker`); whether a candidate enters the pool at all lives in `03-retrieval-filtering` (`home-mixer`).

`visibility-filtering/docs/policy-catalog.md` and `GLOSSARY.md` **do not exist in the repo**. `catalog.rs` is a documentation generator, not a registry (`catalog.rs:23-46`, `:170-173`); **the real registry is `levels.rs` (the per-level rule lists) + `safety_level.rs` (level → list binding)**. Every ordering table below is reconstructed from `action_kind.rs` + `engine.rs` + `levels.rs`.

---

## 1. Two systems, three RPC surfaces

### 1.1 Three internal states, eight external actions

The internal `Verdict` has three states (`verdict.rs:21-29`): `Withheld(Drop(DropReason) | Tombstone(TombstoneReason))`, `Fosnr(Notice::SoftIntervention(FosnrReason) | Notice::Appealable{reason, limited_actions})`, and `Shown{label_interstitial, media, engagement}` (three `Option` slots). The external `VerdictAction` has 8 values (`verdict.rs:9-18`): `Allow / Drop / Tombstone / Interstitial / LimitedEngagement / TweetInterstitial / SoftIntervention / Appealable`.

### 1.2 `filter_tweets` (retrieval / coarse-ranking side, proto) emits only 3 outcomes

`proto.rs:5-37`, wrapped in `rpc.rs:49-57`:

| Internal Verdict | proto `Action.kind` | `filtered_reason` |
|---|---|---|
| `Withheld(Drop(reason))` | `Drop` | `reason.legacy()` |
| `Withheld(Tombstone(_))` | **`Drop`** | `UnspecifiedReason` (tombstone is flattened into drop) |
| `Shown{ media: Some(_), .. }` | `Interstitial(true)` | `ContainNsfwMedia` |
| **`Fosnr(_)` (notice / appealable / soft intervention)** | **`Allow(true)`** | `None` |
| `Shown{ media: None, .. }` (interstitial only / limits only) | **`Allow(true)`** | `None` |

**The most common trap: on the `filter_tweets` surface, FOSNR notices, public-interest interstitials and engagement limits are all passed through as ALLOW, and Tombstone is treated as an ordinary Drop.** Only a media blur becomes INTERSTITIAL. So "the API says allow but the app shows a warning" is not a bug — the two surfaces have different semantics. This surface serves only 4 levels: `FilterAll / TimelineHome / TimelineHomeRecommendations / ImmersiveExpandedRecommendations` (pinned test `safety_level.rs:313-341`).

### 1.3 `evaluate_tweets` (render / hydration side, thrift) exposes all 8

`thrift.rs:30-174`:

| Internal Verdict | thrift result | Lines |
|---|---|---|
| `Withheld(Drop)` | `TweetFieldsResultState::Filtered` | `:43-51` |
| `Withheld(Tombstone)` | `Filtered` + `Action::Tombstone` | `:52-58` |
| `Fosnr(SoftIntervention)` | **`Found`** + `TweetInterstitial{soft_intervention, avoid}` | `:59-69` |
| `Fosnr(Appealable)` | **`Found`** + `TweetInterstitial{limited_engagements, avoid, appealable}` | `:70-85` |
| `Shown` with label_interstitial | `Found` + `TweetInterstitial{interstitial, limited_engagements, media_action, all_media_visibility_results}` | `:86-124` |
| `Shown` with all three slots empty | `Found(None)` = plain ALLOW | `:125-129` |

`verdict_action()` merge rules (`rpc.rs:14-35`): all three slots empty = `Allow`; media only = `Interstitial`; engagement only = `LimitedEngagement`; **any other combination = `TweetInterstitial`**. This surface serves only 5 thrift levels: 8 / 16 / 61 / 82 / 124 (`safety_level.rs:344-370`); `ImmersiveExpandedRecommendations` has `evaluate_tweets = None` (`safety_level.rs:156-162`) — **the immersive video feed only uses the retrieval surface, never the render surface**.

### 1.4 The notification surface is a third semantics; failure / missing states

`rpc.rs:115-120`: `Verdict::Fosnr(_) | Verdict::Shown{..}` always map to `Outcome::Allowed`; only `Withheld` becomes `Dropped`; **and it requires `fail_open_defaults.is_empty()`, otherwise the whole call is `Outcome::Failed`** (`rpc.rs:115`, `:127-128`). Only 4 rules map to a drop reason (`rpc.rs:138-155`): `SuspendedAuthor→ActorSuspended`, `ProtectedAuthor→ActorProtected`, `ViewerBlocksAuthor→RecipientBlocksActor`, `ViewerMutesAndDoesNotFollowAuthor→RecipientMutesActor`; everything else is `Unspecified`.

`Evaluation::{Complete, Partial, NotFound, Deleted, Failed}` (`verdict.rs:340-352`). `Partial` occurs if and only if a failed hydrator is in `must_have()` (`engine.rs:189-221`). `evaluate_tweets_state` returns `None` for `Partial | Failed` → `Outcome::Failed` (`rpc.rs:86`, `:69`); `Deleted` → `NotFound(deleted=true, bounce_deleted=...)` (`rpc.rs:83-85`).

---

## 2. The severity fold: the one and only precedence table

### 2.1 The seven `ActionKind`s (`action_kind.rs:5-13`, attributes `:59-130`)

| ActionKind | severity | Lands | kept_by (preempted by) | Bucket | VerdictAction | Lines |
|---|---|---|---|---|---|---|
| `Appealable` | **18** | `Fosnr` | `&[]` | Withholding | Appealable | `:59-67` |
| `Drop` | **17** | `Withheld` | `&[]` | Withholding | Drop | `:68-76` |
| `Tombstone` | **16** | `Withheld` | `&[]` | Withholding | Tombstone | `:77-85` |
| `LabelInterstitial` | **11** | `Slot(LabelInterstitial)` | `[(LabelInterstitial, KeptEarlierLabelInterstitial)]` | Media | Interstitial | `:86-97` |
| `MediaRestriction` | **10** | `Slot(Media)` | `[(Media, KeptEarlierMedia)]` | Media | Interstitial | `:98-106` |
| `SoftIntervention` | **8** | `Fosnr` | `[(LabelInterstitial, KeptEarlierLabelInterstitial), (Media, KeptEarlierMediaInsteadOfFosnr)]` | Media | SoftIntervention | `:107-121` |
| `LimitedEngagement` | **6** | `Slot(Engagement)` | `&[]` | Engagement | LimitedEngagement | `:122-130` |

`ends_the_fold()`: `Lands::Withheld | Lands::Fosnr => true`, `Lands::Slot(_) => false` (`action_kind.rs:163-168`).

### 2.2 The fold algorithm (`engine.rs`)

1. **Sort** `rules.sort_by_key(|(_, rule, _)| Reverse(rule.action.spec().kind().severity()))` (`:51`). Rust's sort is stable → **within one severity, the written order in `levels.rs` is preserved**.
2. **The user list folds first, the post list second**; in `gate()`, if `user.terminal.is_some()`, **the entire post list is skipped** (`:365-377`).
3. **Short-circuit** `let after = terminal.is_some(); if after && !O::TOTAL { break; }` (`:124-127`). The production observer is not TOTAL → **the first matching Drop / Tombstone / Appealable / SoftIntervention ends evaluation immediately**.
4. **Preemption** `completed = truth.resolves_true() && (!after && action.kind().kept_by(decision.filled()).is_none())` (`:133-135`); in `step()`, `if let Some(effect) = kind.kept_by(filled) { return (None, effect, reads) }` (`:258-260`).
5. **Landing** (`:261-299`): `Withholding` → `Verdict::Withheld` + `Decided` (terminal); `Notice` → `Verdict::Fosnr` + `Decided` (terminal); `LabelInterstitial` / `Media` → fill the slot and **continue**; `Engagement` → first hit is `FilledEngagement`, later hits `limit.add(reason)` accumulate and dedupe (`:279-298`). If nothing terminated, `finish()` → `Verdict::Shown{...}` (`:303-309`).
6. The same rule name may not appear in both the user and post lists (`:334-339`), nor be wired twice within one level (`:52-62`).

### 2.3 "What if a notice and an interstitial both match?"

| Combination | Result | Evidence |
|---|---|---|
| `Appealable`(18) + any interstitial / blur | **Appealable always wins**, kept_by is empty → `Verdict::Fosnr(Appealable)`; the interstitial and blur never take effect | `action_kind.rs:59-67` |
| The `Drop`(17) variant of a FOSNR rule + interstitial(11) / blur(10) | **DROP terminates immediately**, the interstitial never gets a chance | `action_kind.rs:68-76` |
| `SoftIntervention`(8) + an already-filled interstitial(11) or blur(10) | **the soft intervention is discarded** (`KeptEarlierMediaInsteadOfFosnr` / `KeptEarlierLabelInterstitial`), the fold continues | `action_kind.rs:107-121`; `golden_corpus/oon_tweet_label.rs:227-249` (`fosnr_abuse_insults_on_nsfw_media` → only `nsfw_high_precision/blur/sensitive` remains) |
| `LabelInterstitial`(11) + `MediaRestriction`(10) | **two different slots, they stack and coexist** → `VerdictAction::TweetInterstitial`; thrift ships `interstitial` + `media_action` / `all_media_visibility_results` together | `rpc.rs:33`; `thrift.rs:114-123` |
| `LimitedEngagement`(6) + any slot | **always stackable**, multiple reasons accumulate and dedupe, then dedupe again by action_type on the wire | `engine.rs:279-298`; `thrift.rs:366-379`; `golden_corpus/relationship.rs:64-83`, `:102-121` |

### 2.4 Two compile-time invariants

- `a_less_severe_action_kind_never_relies_on_an_earlier_defaults_bucket` (`rule_spec/laws.rs:640-647`): guarantees `Withholding < Media < Engagement` (`defaults.rs:40-44`), so a less severe action never depends on the fail-open default of a more severe bucket.
- `a_user_rule_that_ends_the_fold_never_shadows_a_more_severe_post_rule` (`rule_spec/laws.rs:649-685`): the user list folds first, so any user rule that ends the fold must have an audience **disjoint** from every higher-severity post rule (only `OnlyAuthor` vs `NonAuthors/NonFollowers` counts as disjoint). This explains why `fosnr_author/appealable`(18, `OnlyAuthor`) is wired only at the Hydration level — that level's user list is entirely `NonAuthors/NonFollowers` (`levels.rs:384-391`).

---

## 3. For You has 26 more Drops than Following

### 3.1 The nine levels and their wire numbers (`safety_level.rs:23-33`; numbers pinned by the test at `:383-401`)

| SafetyLevel | thrift | `filter_tweets` | `evaluate_tweets` | Rule list |
|---|---|---|---|---|
| `FilterAll` | 16 | yes | yes | `levels.rs:313-316` |
| `TimelineHome` (Following) | **8** | yes | yes | `levels.rs:318-336` |
| `TimelineHomeRecommendations` (For You) | **61** | yes | yes | `levels.rs:338-381` |
| `TimelineHomeHydration` (render) | **82** | no | yes | `levels.rs:383-402` |
| `TimelineHomePromotedHydration` (ads) | 124 | no | yes | `levels.rs:404-415` |
| `ImmersiveExpandedRecommendations` | — | yes | **no** | `levels.rs:485-510` |
| `QuotedTweetRules` | — | no | no (inner-quote validation) | `levels.rs:222-231` |
| `NotificationsFollow` | 246 | no | no (notification surface) | `levels.rs:301-311` |
| `NotificationsWriterV2` | 72 | no | no (notification surface) | `levels.rs:233-299` |

**There is no Search / Profile / Explore level.** "Not recommended but searchable" and "profile-only visibility" have no corresponding tier in this subsystem; they are decided by other services and are not public.

### 3.2 For You phase one: the user list, 20 rules, all Drop(17), in written order

| rule_name | audience | Trigger condition | Evidence |
|---|---|---|---|
| `suspended_author/drop`, `deactivated_author/drop`, `erased_author/drop`, `offboarded_author/drop` | NonAuthors | `AuthorIsSuspended` / `AuthorIsDeactivated` / `AuthorIsErased` / `AuthorIsOffboarded` → `AuthorAccountIsInactive` | `author_rules.rs:7-12`, `:14-19`, `:21-33` |
| `protected_author/drop` | **NonFollowers** | `AuthorIsProtected` | `author_rules.rs:35-40` |
| `viewer_blocks_author/drop`, `viewer_mutes_author/drop` | Everyone | `!ViewerLoggedOut && ViewerBlocksAuthor` / `ViewerMutesAuthor` | `author_rules.rs:42-47`, `:49-54` |
| `nsfw_user_author/drop/nsfw_media`, `nsfw_admin_author/drop/nsfw_media` | NonAuthors | `AuthorIsNsfwUser` / `AuthorIsNsfwAdmin` → `ContainNsfwMedia` | `author_rules.rs:155-167` |
| `nsfw_{high_recall,high_precision,avatar_image,banner_image,near_perfect}_user_label/drop/unspecified` ×5 | NonAuthors | `AuthorHasLabel(the identically named AuthorLabel)` | `author_rules.rs:169-202` |
| `{spam_high_recall,compromised,read_only,impersonation_high_precision}_user_label/drop/unspecified` ×4 | NonAuthors | `AuthorHasLabel(identically named)` | `author_rules.rs:204-230` |
| `abusive_high_recall_user_label/drop/unspecified`, `do_not_amplify_user_label/drop/unspecified` | **NonFollowers** | `AuthorHasLabel(AbusiveHighRecall)` / `AuthorHasLabel(DoNotAmplify)` | `author_rules.rs:232-237`, `:239-244` |

Wiring source: the first 8 = `AUTHOR_STATE_DROPS` + `VIEWER_BLOCKS_OR_MUTES_AUTHOR_DROPS` (`levels.rs:90-99`, `:340-341`); the middle 7 NSFW rules = `levels.rs:342-350`; the last 6 = `OON_AUTHOR_LABEL_DROPS` (`levels.rs:101-108`, `:351`).

### 3.3 Phase two: the post list, 40 Drop(17) rules + 6 blur(10) rules, in written order

| rule_name | audience | Trigger condition | Evidence |
|---|---|---|---|
| `viewer_mutes_retweets/drop/unspecified` | Everyone | `!ViewerLoggedOut && TweetIsRetweet && ViewerMutesRetweetsFromAuthor` | `author_rules.rs:56-66` |
| `pdna/drop/nsfw_high_precision_safety_result`, `bounce/drop/bounced`, `spam/drop/undesirable` | NonAuthors | `PDNA` / `BOUNCE`→`TweetIsBounced` / `SPAM`→`PossiblyUndesirable` | `tweet_rules.rs:28-33`, `:35-40`, `:49-54` |
| `for_emergency_use_only/drop/unspecified` | Everyone | `FOR_EMERGENCY_USE_ONLY` | `tweet_rules.rs:56-61` |
| `fosnr_{hateful_conduct,violent_speech,abuse,civic_integrity}/drop/undesirable` ×4 | NonAuthors | identically named labels | `tweet_rules.rs:141-167` |
| `nullcasted_tweet/drop`, `stale_tweet/drop/unspecified` | Everyone | `TweetIsNullcast && !TweetIsRetweet && !TweetIsCommunityTweet` / `TweetIsSupersededEdit && !IsQuotedInnerTweet && !TweetIsRetweet && !IsSourceTweet` | `tweet_rules.rs:215-220`, `:222-232` |
| `legal_takedown/drop/unspecified`, `local_laws_takedown/drop/unspecified` | NonAuthors | `TweetLegalTakedownInRequestCountry` / `TweetLocalLawsTakedownInRequestCountry` (§8) | `tweet_rules.rs:244-249`, `:251-256` |
| `sensitive_viewer_{logged_out,underage,no_stated_age}/drop/{media_label,nsfw_flag,text_or_card_label}` ×9 | NonAuthors | see §7 | `tweet_rules.rs:294-380` |
| `exclusive_tweet/drop/logged_out` / `/retweet` / `/non_super_follower` | Everyone / Everyone / NonAuthors | all require `TweetHasExclusiveContent`, plus respectively `ViewerLoggedOut` / `TweetIsRetweet` / nothing; the latter two also require `!ViewerIsConversationAuthor && !ViewerSuperFollowsAuthor` | `tweet_rules.rs:396-401`, `:403-413`, `:415-424` |
| `trusted_friends_tweet/drop/unspecified` | NonAuthors | `TweetIsTrustedFriendsTweet && !ViewerIsTrustedFriendsListMemberOrOwner` | `tweet_rules.rs:444-452` |
| `geo_restricted_media/drop/unspecified`, `dmca_media/drop/unspecified` | NonAuthors / **Everyone** | `TweetMediaGeoRestrictedInRequestCountry` / `TweetHasDmcaMedia` | `tweet_rules.rs:891-896`, `:884-889` |
| `nsfw_user_tweet_flag/drop/nsfw_media`, `nsfw_admin_tweet_flag/drop/nsfw_media` | **Everyone** | `TweetNsfwUserFlag` / `TweetNsfwAdminFlag` | `tweet_rules.rs:898-903`, `:905-910` |
| `gore_and_violence_high_precision/drop/nsfw_media`, `nsfw_high_recall/drop/nsfw_media`, `nsfw_high_precision/drop/nsfw_media`, `nsfw_card_image/drop/nsfw_media` | NonAuthors | identically named labels | `tweet_rules.rs:596-603`, `:912-918`, `:478-483`, `:679-684` |
| `soft_nsfw_new_user/drop/unspecified` | NonAuthors | `RequestHasSoftNsfwNewUserDrop && ViewerIsNewAccount && SOFT_NSFW` | `tweet_rules.rs:919-928` |
| `do_not_amplify/drop/undesirable`, `malicious_url/drop/undesirable` | **NonFollowers** | `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | `tweet_rules.rs:930-935`, `:937-942` |
| `spam_high_recall/drop/undesirable`, `brazil_election_legal/drop/undesirable`, `fosnr_abuse_insults/drop/undesirable` | NonAuthors | `SPAM_HIGH_RECALL` / `BRAZIL_ELECTION_LEGAL && RequestCountryIs("br")` / `FOSNR_ABUSE_INSULTS` | `tweet_rules.rs:944-949`, `:951-959`, `:169-174` |
| `HOME_BLURS`, 6 `*/blur/*` rules (severity 10, listed last) | NonAuthors | see §6.1, **all preempted in the recommendations feed** | `levels.rs:201-208`, `:367` |

Grouping source `levels.rs:354-379`. **`soft_nsfw_new_user` is a triple gate: the DDG switch `soft_nsfw_tweet_label_new_user_rule_enabled` defaults to `false` (`client_switches.rs:15`, `:141-147`), and "new user" means `ViewerIsNewAccount` = a new VIEWER account (`rule_spec/features/viewer.rs:73-75`), not a new author account. The code is present but off by default; it cannot explain a real reach problem.**

### 3.4 The 26 rules missing from `TimelineHome` (Following, thrift 8)

`levels.rs:318-336`. The pinned test `timeline_home_recommendations_starts_with_timeline_home` (`levels.rs:550-556`) guarantees that **the Recommendations list starts with the Home list as a prefix**; the difference is exactly these 26 rules:

| Side | Rules missing from Home | Count |
|---|---|---|
| user | 7 NSFW author-flag / author-label drops (`levels.rs:342-350`) | 7 |
| user | the 6 `OON_AUTHOR_LABEL_DROPS` (`levels.rs:101-108`) | 6 |
| post | `dmca_media/drop/unspecified` (`levels.rs:368`) | 1 |
| post | 7 NSFW tweet-flag / label drops + `soft_nsfw_new_user` (`levels.rs:369-377`) | 7 |
| post | `OON_POST_DROPS` = `do_not_amplify` / `malicious_url` / `spam_high_recall` / `brazil_election_legal` (`levels.rs:215-220`) | 4 |
| post | `fosnr_abuse_insults/drop/undesirable` (`levels.rs:379`) | 1 |

**Following keeps all 6 `HOME_BLURS` and has no NSFW Drop ahead of them → the same borderline post is "blurred" in the Following feed and "gone" in the For You feed.** Golden corpus: the same `MALICIOUS_URL` post is allowed even for strangers on `TimelineHome` (`golden_corpus/oon_tweet_label.rs:17-31`, `:30`).

### 3.5 How the other levels differ

- **`ImmersiveExpandedRecommendations`** (`levels.rs:485-510`): has `OON_AUTHOR_LABEL_DROPS` + `OON_POST_DROPS` + `MEDIA_TAKEDOWN_DROPS` (DMCA + geo) + the gore drop, but **not** `NSFW_HIGH_PRECISION_DROP` / `NSFW_CARD_IMAGE_DROP` / `NSFW_*_TWEET_FLAG_DROP`; instead it uses `nsfw_sensitive_viewer_tweet/drop/nsfw_media` (`!ViewerAllowsSensitiveMedia && IS_NSFW_SENSITIVE_TWEET`, `tweet_rules.rs:382-387`) and, on the user side, `nsfw_sensitive_viewer_user/drop/nsfw_media` (`:389-394`). **Turning on the sensitive-media setting makes it visible** (`golden_corpus/age_gating.rs:138-180`).
- **`TimelineHomePromotedHydration`** (ads, 124): the user list contains **only** `blocked_viewer/limited_engagement`; the post list matches Hydration but **drops `REACTED_TO_RULES`** (`levels.rs:404-415`).
- **`FilterAll`** (16): a single rule `filter_all/drop/unspecified` (`when: all![]`, always true, Everyone, `tweet_rules.rs:14-19`) → **unconditionally drops everything**; it is also the only level with `unspecified_drop_is_exact: true` (`safety_level.rs:123`), which makes `UnspecifiedReason` land as the exact `action::DropReason::Unspecified` (`thrift.rs:489-491`).
- **`TimelineHomeHydration`** (82) is the only level with all 8 verdict kinds: `fosnr_author/appealable`(18, OnlyAuthor, `tweet_rules.rs:201-206`) → the various Drop(17) rules → 12 Tombstone(16) rules → `public_interest/label_interstitial` and `for_emergency_use_only/label_interstitial`(11) → 19 MediaRestriction(10) rules → `fosnr_abuse_insults_follower/soft_intervention/abuse`(8) → 14 LimitedEngagement(6) rules. Lists: `levels.rs:383-402` + `HYDRATION_INJECTED_RULES:417-432` + `HYDRATION_MEDIA_AND_LIMITS:434-477`.
- **The two faces of `for_emergency_use_only`**: the Drop variant is wired only at Home / Recommendations / Immersive (`levels.rs:326`, `:359`, `:498`), the interstitial variant only at Hydration / PromotedHydration (`levels.rs:431`). **So a post carrying this label cannot enter any home feed, but when rendered directly it gets a dynamic emergency interstitial** (`golden_corpus/label_interstitial.rs:185-213`); if the source starts with `bot_id_` / `Abuse` / `hse`, or is exactly one of `["A","B","AB","OneOff","VotingMisinformation","HackedMaterials","Scams","PlatformManipulation"]`, no interstitial is generated and the post is allowed (`rule_spec.rs:767-785`; corpus `label_interstitial.rs:215-222`).

---

## 4. `NonAuthors` vs `NonFollowers`: two completely different boundaries

### 4.1 Exact definitions (`rule_spec/engine.rs:67-68`, same values in UserEngine at `:98-99`)

```rust
NON_AUTHORS   = RuleCond::Not(&ViewerIsAuthor.leaf())
NON_FOLLOWERS = all![!ViewerIsAuthor, !ViewerFollowsAuthor]
```

`Audience` has four values, `Everyone / NonAuthors / NonFollowers / OnlyAuthor` (`rule_spec/rule.rs:100-105`, condition expansion `:108-115`). **`NonAuthors` = dropped for everyone except the author, followers included — this is an "author exemption", not a "follower exemption". `NonFollowers` = the author and followers are both allowed, only strangers are dropped — this is the real out-of-network restriction.** All `sensitive_viewer_*`, `nsfw_*`, `legal_takedown`, `local_laws_takedown` and `fosnr_*_drop` rules are `NonAuthors` → **the author always sees their own violating post**.

### 4.2 The complete `NonFollowers` rule list

**User side, 14 rules:**

| rule_name | Condition | Wired at | Evidence |
|---|---|---|---|
| `protected_author/drop` | `AuthorIsProtected` | Home / Rec / Immersive / Hydration / notifications | `author_rules.rs:35-40` |
| `abusive_high_recall_user_label/drop/unspecified` | `AuthorHasLabel(AbusiveHighRecall)` | Rec / Immersive / NotifWriterV2 | `author_rules.rs:232-237` |
| `do_not_amplify_user_label/drop/unspecified` | `AuthorHasLabel(DoNotAmplify)` | same as above | `author_rules.rs:239-244` |
| `not_graduated_user_label/drop/unspecified`, `agatha_spam_top_user_user_label/drop/unspecified`, `engagement_spammer_user_label/drop/unspecified` | `AuthorHasLabel(NotGraduated)` / `(AgathaSpamTopUser)` / `(EngagementSpammer)` | notifications only | `author_rules.rs:246-251`, `:253-258`, `:260-265` |
| `blink_worst_user_label/drop/unspecified`, `downrank_spam_reply_user_label/drop/unspecified` | `AuthorHasLabel(BlinkWorst) && ViewerHasUqfEnabled && !ViewerHasBlinkLabel` / `AuthorHasLabel(DownrankSpamReply)` | notifications only | `author_rules.rs:267-276`, `:278-283` |
| `no_confirmed_email/drop/unspecified`, `no_confirmed_phone/drop/unspecified`, `no_default_profile_image/drop/unspecified` | `ViewerFiltersNoConfirmedEmail && !AuthorHasConfirmedEmail` / `ViewerFiltersNoConfirmedPhone && !AuthorHasVerifiedPhone` / `ViewerFiltersDefaultProfileImage && AuthorHasDefaultProfileImage` | notifications only | `author_rules.rs:110-115`, `:117-122`, `:124-132` |
| `no_new_users/drop/unspecified`, `no_not_followed_by/drop/unspecified`, `only_people_i_follow/drop/unspecified` | `ViewerFiltersNewUsers && AuthorIsNewAccount` / `ViewerFiltersNotFollowedBy && !AuthorFollowsViewer` / `ViewerMentionFilterIsFollowing` | notifications only | `author_rules.rs:134-139`, `:141-146`, `:148-153` |

There is also `quoted_viewer_mutes_author_not_following/drop`: its declared audience is `NonAuthors`, but its `when` includes `!ViewerFollowsAuthor` (`author_rules.rs:67-73`, wired at `levels.rs:229`) → **effectively a follower exemption**, used only for inner-quote validation.

**Post side, 10 rules:**

| rule_name | Condition | Wired at | Evidence |
|---|---|---|---|
| `do_not_amplify/drop/undesirable`, `malicious_url/drop/undesirable` | `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | Rec / Immersive | `tweet_rules.rs:930-935`, `:937-942` |
| `fosnr_abuse_insults_non_follower/drop/undesirable` | `FOSNR_ABUSE_INSULTS && ClientHas(FosnrRules)` | Hydration / PromotedHydration | `tweet_rules.rs:176-184` |
| `spam_high_recall_oon/drop/undesirable` | `SPAM_HIGH_RECALL` | only `NOTIFICATIONS_WRITER_V2_MEDIA_TAGGED` (`levels.rs:274`) | `tweet_rules.rs:1022-1027` |
| `risky_high_viz_reply_oon/drop/unspecified` | `RISKY_HIGH_VIZ_REPLY` | notification mention / reply / media_tagged only (`levels.rs:259`, `:275`) | `tweet_rules.rs:1029-1034` |
| `duplicate_mention_uqf/drop/unspecified`, `abusive_uqf/drop/unspecified`, `untrusted_url_uqf/drop/unspecified`, `downrank_spam_reply_uqf/drop/unspecified` | `DUPLICATE_MENTION` / `ABUSIVE` / `UNTRUSTED_URL` / `DOWNRANK_SPAM_REPLY`, all four `&& ViewerHasUqfEnabled` | notifications only (`LOW_QUALITY_AND_UQF_DROPS`) | `tweet_rules.rs:985-993`, `:995-1000`, `:1002-1010`, `:1012-1020` |
| `only_people_i_follow_outside_community/drop/unspecified` | `ViewerMentionFilterIsFollowing && !TweetIsCommunityTweet` | notifications only | `tweet_rules.rs:21-26` |

### 4.3 Key correction: these labels suppress **notifications**, not For You

`LOW_QUALITY_AND_UQF_DROPS` (`levels.rs:190-199`) and `COMMUNITY_AND_SPAM_DROPS` (`levels.rs:181-188`) **are wired**, and their wiring points are on the notification surface:

| Constant | Wiring location | Level |
|---|---|---|
| `COMMUNITY_AND_SPAM_DROPS` | `levels.rs:253`, `:292` | `NOTIFICATIONS_WRITER_V2_MENTION`, `NOTIFICATIONS_WRITER_V2_RETWEET_SOURCE` |
| `LOW_QUALITY_AND_UQF_DROPS` | `levels.rs:258`, `:297` | the same two |
| `RISKY_HIGH_VIZ_REPLY_OON_DROP_UNSPECIFIED` | `levels.rs:259`, `:275` | `NOTIFICATIONS_WRITER_V2_MENTION`, `NOTIFICATIONS_WRITER_V2_MEDIA_TAGGED` |
| `SPAM_HIGH_RECALL_OON_DROP_UNDESIRABLE` | `levels.rs:274` | `NOTIFICATIONS_WRITER_V2_MEDIA_TAGGED` |

`NOTIFICATIONS_WRITER_V2_REPLY = NOTIFICATIONS_WRITER_V2_MENTION` (`levels.rs:263`). **Neither constant is wired into `TIMELINE_HOME_RECOMMENDATIONS` or `TIMELINE_HOME`.** So `DUPLICATE_CONTENT`, `DUPLICATE_MENTION`, `ABUSIVE`, `UNTRUSTED_URL`, `DOWNRANK_SPAM_REPLY`, `SMYTE_SPAM_TWEET` and `RISKY_HIGH_VIZ_REPLY` **suppress notifications, not For You reach**. Concretely: Grox's `RISKY_HIGH_VIZ_REPLY` (botmaker rule 25026, `spamScore >= 0.97`, TTL 14 days, `botmaker-rules/scarecrow/bot/GroxTweetProcessor.bot:1`, `:8`, `:27-29`) **stops the person you replied to from getting a reply notification, but does not remove that reply from For You**.

Two exceptions you must keep separate: `SPAM_HIGH_RECALL` **does** drop out of For You — via `spam_high_recall/drop/undesirable` inside `OON_POST_DROPS` (`NonAuthors`, `levels.rs:218`, `:378`), not via the `NonFollowers` `_oon` variant on the notification surface; and `LOW_QUALITY` only DROPs on the notification surface for posts created **before 2019-04-01** (`!TweetCreatedAfter(1554076800000)`, `tweet_rules.rs:961-969`) — later posts get the render-layer public-interest interstitial instead (§5.2).

### 4.4 Reverse-engineering from the golden corpus (the hardest evidence)

| Corpus case | Result | Lines |
|---|---|---|
| `abusive_high_recall_user_label`, `do_not_amplify_user_label` | **only `Role::NonFollower` is dropped; `Follower` and `Author` are both allowed** | `golden_corpus/oon_user_label.rs:129-143`, `:159-173` |
| `nsfw_high_recall` / `nsfw_high_precision` / `spam_high_recall` / `compromised` / `read_only` / `impersonation` / `nsfw_avatar` / `nsfw_banner` / `nsfw_near_perfect` author labels | **followers are dropped too; only the Author is allowed** (`NonAuthors`) | `golden_corpus/oon_user_label.rs:10-128`, `:144-158` |
| `malicious_url`, `do_not_amplify` post labels | NonFollower + LoggedOut dropped; Follower + Author allowed; **on `TimelineHome` even the NonFollower is allowed** | `golden_corpus/oon_tweet_label.rs:17-31`, `:47-61` |
| `nsfw_high_recall` post label | **followers are dropped too** | `golden_corpus/oon_tweet_label.rs:32-46` |
| `brazil_election_legal` | **even if you follow the author, a request from `br` is still dropped** (`NonAuthors` + a country condition, not an OON rule) | `golden_corpus/oon_tweet_label.rs:77-132` |
| `fosnr_abuse_insults` | Author → `appealed(ABUSE, level=1)`; NonFollower / LoggedOut → drop; **Follower → soft_intervention**; an old client with `FosnrRules` off → `fosnr_fallback/drop`; **on Recommendations, Follower and NonFollower are both dropped** | `golden_corpus/oon_tweet_label.rs:133-196` |

`Role::views()`: `Follower` additionally sets `Hydrator::Follows`; `LoggedOut` clears every relationship edge (`golden_corpus/mod.rs:132-165`).

---

## 5. Label enums and the label → treatment map

### 5.1 Author-level `AuthorLabel`: the full enum is in the repo (`author.rs:20-37`, `#[repr(u8)]`, stored as a `u64` bitmap `:40-52`)

```
NsfwHighRecall=0   NsfwHighPrecision=1  NsfwNearPerfect=2   NsfwAvatarImage=3
NsfwBannerImage=4  SpamHighRecall=5     AbusiveHighRecall=6 Compromised=7
ReadOnly=8         ImpersonationHighPrecision=9  DoNotAmplify=10  NotGraduated=11
AgathaSpamTopUser=12  EngagementSpammer=13  BlinkWorst=14  DownrankSpamReply=15
```

The post-level `SafetyLabelType` is `pub use xai_x_thrift::tweet_safety_label::SafetyLabelType;` (`safety_labels.rs:1`) — **the authoritative IDL enum and its numeric IDs are not in this repo and are not public**; the repo code references 53 variants.

### 5.2 Post-level label → treatment

| SafetyLabelType | Treatment | audience | Evidence |
|---|---|---|---|
| `PDNA` | DROP `NsfwHighPrecisionSafetyResult` | NonAuthors | `tweet_rules.rs:28-33` |
| `BOUNCE` | DROP `TweetIsBounced`; inner quote → **Tombstone(Bounced)** | NonAuthors / Everyone | `tweet_rules.rs:35-47` |
| `SPAM` / `SPAM_HIGH_RECALL` | DROP `PossiblyUndesirable` | NonAuthors | `tweet_rules.rs:49-54`, `:944-949` |
| `FOR_EMERGENCY_USE_ONLY` | DROP at all three retrieval levels; dynamic interstitial at render (§3.5) | Everyone | `tweet_rules.rs:56-68` |
| `LOW_QUALITY` | render-layer **public-interest interstitial** + `NonCompliant` limits (after 2019-04-01); notification surface DROPs older posts | Everyone / NonAuthors | `tweet_rules.rs:70-87`, `:961-969`; `rule_spec.rs:744-754` |
| `MISINFO_CIVIC` / `CRISIS` / `GENERIC` / `MEDICAL`, `IPI_DEVELOPMENT_ONLY` | public-interest interstitial, the limit reason is decided by the label's `source` string; `IPI_DEVELOPMENT_ONLY` uses the `DEVELOPMENT_ONLY_PUBLIC_INTEREST` interstitial + `NonCompliant` | Everyone | `rule_spec.rs:755-758`, `:759-762` |
| `FOSNR_HATEFUL_CONDUCT` / `VIOLENT_SPEECH` / `ABUSE` / `CIVIC_INTEGRITY` | DROP for non-authors; **the author gets Appealable, level=3, 13 limited actions** | NonAuthors / OnlyAuthor | `tweet_rules.rs:141-167`, `:108-132`, `:201-206` |
| `FOSNR_ABUSE_INSULTS` | Rec: DROP for all non-authors; Hydration: strangers DROP, **followers soft_intervention(level=1)**, **author Appealable(level=1, only `EditTweet` blocked)** | see left | `tweet_rules.rs:169-199`, `:133-138` |
| `FOSNR_APPEAL_SUBMITTED` | **changes no verdict**, only sets `appeal_submitted` to true (§10.1) | — | `rule_spec.rs:675` |
| `NSFW_HIGH_PRECISION` | Rec / Immersive: DROP `ContainNsfwMedia`; Home: blur; Hydration: country × client → tombstone / blur+age_prompt / legacy (§6.4) | NonAuthors (the `*_all_users` variants are Everyone) | `tweet_rules.rs:454-584` |
| `NSFW_HIGH_RECALL` | DROP `ContainNsfwMedia` | NonAuthors | `tweet_rules.rs:912-918` |
| `GORE_AND_VIOLENCE_HIGH_PRECISION` | Rec: DROP; Home: blur `Violence`; Hydration: with `GoreBlurIgnoresSettings` on, **forces a blur regardless of the viewer's setting** | NonAuthors | `tweet_rules.rs:586-667` |
| `NSFW_CARD_IMAGE` | Rec: DROP; Home / Hydration: blur `Sensitive` / tombstone / legacy | NonAuthors | `tweet_rules.rs:669-749` |
| `NSFW_TEXT` / `NSFW_TEXT_HIGH_PRECISION` / `NSFW_VIDEO` | participate in `IS_NSFW_SENSITIVE_TWEET`; `NSFW_TEXT` + `NSFW_CARD_IMAGE` trigger the logged-out / underage / no-stated-age hard DROPs | NonAuthors | `rule_spec/conditions.rs:25-31`, `:48-59`; `tweet_rules.rs:313-380` |
| `SOFT_NSFW` | DROP, **triple gate and the DDG switch defaults to false** (§3.3) | NonAuthors | `tweet_rules.rs:919-928`; `client_switches.rs:15`, `:141-147` |
| `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | **DROP, strangers only** | NonFollowers | `tweet_rules.rs:930-935`, `:937-942` |
| `BRAZIL_ELECTION_LEGAL` | DROP, condition `RequestCountryIs("br")` | NonAuthors | `tweet_rules.rs:951-959` |
| `DYNAMIC_PRODUCT_AD` | **LimitedEngagement(DynamicProductAd)**, 8 limited actions, no copy | Everyone | `tweet_rules.rs:1151-1156` |
| `DUPLICATE_CONTENT` / `SMYTE_SPAM_TWEET` / `ABUSIVE` / `UNTRUSTED_URL` / `DUPLICATE_MENTION` / `DOWNRANK_SPAM_REPLY` / `RISKY_HIGH_VIZ_REPLY` | **notification surface only** (§4.3) | NonAuthors / NonFollowers | `tweet_rules.rs:971-1034`; `levels.rs:190-199`, `:253-259` |
| `EGREGIOUS_NSFW`, `NSFA_*`, `GROK_*`, `PTOS_REVIEWED`, `NSFW_REPORTED_HEURISTICS`, `GORE_AND_VIOLENCE_REPORTED_HEURISTICS`, `DEPRECATED_LABEL_144` | **never read by visibility-filtering**, used only in home-mixer's brand-safety grading | — | `home-mixer/models/brand_safety.rs:73-99` |

### 5.3 Label metadata decides FOSNR semantics

`SafetyLabelMap{types, by_agent, sources}` (`safety_labels.rs:7-11`): `by_agent` is set when the source is a `ToolAction` (a human / support-tool label) (`:51-56`); `sources` **reads the source string for only 7 labels** (`SOURCE_READ_LABELS`, `:14-22`): `LOW_QUALITY, MISINFO_CIVIC, MISINFO_GENERIC, MISINFO_MEDICAL, MISINFO_CRISIS, IPI_DEVELOPMENT_ONLY, FOR_EMERGENCY_USE_ONLY`. `fosnr_reason()`: `proactive = !labels.is_by_agent(label)`, `appeal_submitted = labels.has_label(FOSNR_APPEAL_SUBMITTED)` (`rule_spec.rs:665-677`) → **a human-applied FOSNR label does not count as proactive enforcement**. The `LOW_QUALITY` source is uppercased with underscores stripped and compared against 30 `SafetyResultReason` values (`rule_spec.rs:694-732`); no match falls back to `ONE_OFF` (`:752`).

There are three label sources: `BotMakerAction` (carries `rule_id`), `ToolAction(AgentTool, actor_ldap)`, `GrokAnnotationAction` (`visibility-filtering-client/tweet_safety_label.rs:188-226`). Labels also carry `score / applicable_users / holdback_experiment / created_at_msec / expires_at_msec / applicable_countries` (same location). **The `applicable_countries` field is never read by any visibility-filtering rule**; rules only use `RequestCountryIn` / `RequestCountryIs`.

---

## 6. Adult / violent content: dropped in For You, blurred only at render

### 6.1 `PREEMPTED`: 6 blur rules can never fire on Recommendations

`golden_corpus/mod.rs:673-710` pins this down (see also `WIRED_DIFFERENTLY` in `rule_spec/laws.rs:687-694`):

| Preempted blur rule | Preemptor (Drop 17, broader condition, no `!ViewerAllowsSensitiveMedia`) |
|---|---|
| `nsfw_high_precision/blur/nudity`, `nsfw_high_precision/blur/sensitive` | `nsfw_high_precision/drop/nsfw_media` |
| `gore_and_violence_high_precision/blur` | `gore_and_violence_high_precision/drop/nsfw_media` |
| `nsfw_card_image/blur/sensitive` | `nsfw_card_image/drop/nsfw_media` |
| `nsfw_admin/blur/sensitive` | `nsfw_admin_author/drop/nsfw_media` + `nsfw_admin_tweet_flag/drop/nsfw_media` |
| `nsfw_user/blur/sensitive_user` | `nsfw_user_author/drop/nsfw_media` + `nsfw_user_tweet_flag/drop/nsfw_media` |

**Conclusion: adult / violent content in For You is not blurred, it is dropped outright; blurring only happens at the Hydration (render) layer.** Comparison case `golden_corpus/local_regulations.rs:27-54`: the same `NSFW_HIGH_PRECISION` media post → tombstone/drop on Recommendations, plain `Sensitive` blur on `TimelineHome`.

### 6.2 The four country lists (`params.rs:43-48`, code defaults `:77-91`)

Bitmap `CountryCodes([u64; 11])`, accepts only 2-letter lowercase codes (`params.rs:99-132`), **refreshed from feature switches every 30 seconds** (`params.rs:370-379`) — the values below are **code defaults**; the live lists are decided by non-public YAML.

| CountryList | feature switch key | Default members |
|---|---|---|
| `AgeVerification` = `Tombstone` | `country_specific_nsfw_content_gating_age_verification_countries` / `..._tombstone_countries` | **30 countries**: `at au be bg br cy cz de dk ee es fi fr gb gr hr hu ie it lt lu lv mt nl pl pt ro se si sk` (EU/EEA + UK + Brazil + Australia) |
| `NsfwGating` | `country_specific_nsfw_content_gating_countries` | **16 countries**: `ar au br ca de es fr gb id it kr mx nl ph pt th` |
| `LocalRegulations` | `country_specific_nsfw_content_gating_local_regulations_countries` | **`["in"]` (India only)** |

`LocalRegulations` has exactly one use: `nsfw_high_precision/tombstone/local_regulations` (`tweet_rules.rs:485-493`). Corpus `golden_corpus/local_regulations.rs:27-54`: request country `in` → **tombstone even with the sensitive-media setting on**; author account country `in` but request from elsewhere → plain blur; web + `us` → plain blur.

### 6.3 Client capability and the 6 switches

`VerifyBlurSupport::{Unsupported, IosNeedsUpdate, AndroidNeedsUpdate, Supported}` (`viewer.rs:202-208`), **code default `Some(Unsupported)`** (`viewer.rs:298-301`). The four feature switch keys (`client_switches.rs:37-44`): `Unsupported → age_verification_uk_tombstone_rule_enabled`, `IosNeedsUpdate → age_verification_ios_tombstone_rule_enabled`, `AndroidNeedsUpdate → age_verification_android_tombstone_rule_enabled`, `Supported → age_verification_blurred_media_interstitial_rule_enabled`. With no TwitterContext, `ClientCapability::DEFAULT` is used directly; otherwise each key is read as a bool, falling back to the default when absent (`client_switches.rs:118-139`).

The **code defaults** of the 6 `ClientSwitch` flags (`viewer.rs:212-230`, key mapping `client_switches.rs:18-35`):

| switch | Default | feature switch key |
|---|---|---|
| `StaleTweetLimits` | **true** | `stale_tweet_limited_actions_rules_enabled` |
| `FosnrRules` | **true** | `freedom_of_speech_not_reach_rules_enabled` |
| `ModernBlur` | **false** | `media_visibility_treatments_blurred_media_interstitial_enabled` |
| `CommunityViewerRemovedLimits` | **false** | `community_tweet_viewer_removed_limited_actions_rules_enabled` |
| `GoreBlurIgnoresSettings` | **false** | `media_visibility_treatments_blurred_media_interstitial_ignore_settings_enabled` |
| `FosnrFallbackDrops` | **false** | `freedom_of_speech_not_reach_fallback_drop_rules_enabled` |

**Keep these apart**: the 8 client classes in `fixtures.rs:29-134` (`web` app_id 3033300 = Supported+MODERN, `ios_current` 129032, `ios_outdated`, `android_current` 258901, `android_outdated`, `android_without_fosnr`, `mac_app` 557701 = Unsupported+LEGACY, `third_party_client` app_id 0) are **test fixtures, not production configuration**. Which real client gets which capability is decided by the non-public `age_verification.yml` / `media_visibility_treatments.yml` (`params.rs:26-34`). `MODERN = DEFAULT_ON + ModernBlur + GoreBlurIgnoresSettings` (`fixtures.rs:40`).

### 6.4 The `NSFW_HIGH_PRECISION` render-layer decision tree

**Time cutoff `NSFW_HIGH_PRECISION_CHANGED_AT = 1705536000000` (2024-01-18 UTC)** (`tweet_rules.rs:454`). It is evaluated from the snowflake: `tweet_timestamp_ms(id) = (id >> 22) + 1288834974657` (`mod.rs:35-39`), and `created_after()` is **strictly greater than** (`context.rs:188-190`).

| Condition (top to bottom, first match wins) | Treatment | Lines |
|---|---|---|
| request country ∈ `LocalRegulations` (in) | **Tombstone(LocalRegulations)**, ignores the sensitive-media setting | `tweet_rules.rs:485-493` |
| `Unsupported` + request country ∈ Tombstone (30 countries) + not age-verified | **Tombstone(SensitiveViewerAgeVerification)** | `:495-504` |
| `IosNeedsUpdate` / `AndroidNeedsUpdate` + same as above | Tombstone(UpdateAppIos) / Tombstone(UpdateAppAndroid) | `:506-515`, `:517-526` |
| `Supported` + request country ∈ AgeVerification (30 countries) + not verified + **before / after the cutoff** | blur `Sensitive` / blur `Nudity`, both with **AGE_VERIFICATION_PROMPT** | `:528-538`, `:552-562` |
| `Everyone` + `!ViewerAllowsSensitiveMedia` + `ModernBlur` + before / after the cutoff | blur `Sensitive` / `Nudity` (**the author is blurred too**) | `:540-550`, `:564-574` |
| `NonAuthors` + `!ViewerAllowsSensitiveMedia` (Home level) + after / before the cutoff | blur `Nudity` / `Sensitive` | `:456-465`, `:467-476` |
| `Everyone` + `!ModernBlur` | **legacy_nsfw_interstitial** (the old whole-post interstitial) | `:576-584` |
| Rec / Immersive level | **DROP `ContainNsfwMedia`** | `:478-483` |

- **Four ways to escape the tombstone**: the `age_verified_18` label / being the author / `has_idv_premium` / request country `us` → all degrade to a plain blur (`golden_corpus/age_verification.rs:163-233`). **A failed `ViewerProfile` + `ViewerLabels` lookup still gates** (fail-closed, `:358-377`).
- The post-level nsfw flag (`NSFW_ACCOUNT`) goes through the same machinery but uses the `AgeVerification` list rather than the `Tombstone` list (`tweet_rules.rs:813-859`) — the two lists have identical default members, so they only differ when the switches drift. `NSFW_ADMIN` takes precedence over `NSFW_USER` (`golden_corpus/interstitial.rs:33-54`); when admin and gore both match, admin wins (`golden_corpus/age_verification.rs:587-614`).
- Blur wire shape: `BlurredImageInterstitial{reason, opacity: 0.8, interstitial_action, available_verification_options}` (`thrift.rs:454-467`); with an age prompt the verification options are `[SELFIE, PERSONA]` (`thrift.rs:449-452`).

### 6.5 `GORE_AND_VIOLENCE_HIGH_PRECISION`

| Condition | Treatment | Lines |
|---|---|---|
| Rec / Immersive | DROP `ContainNsfwMedia` | `tweet_rules.rs:596-603` |
| `NonAuthors` + `!ViewerAllowsSensitiveMedia` (Home) | blur `Violence` | `:586-594` |
| **`ClientHas(GoreBlurIgnoresSettings)` (ignores the viewer's setting)** | **forced blur `Violence`** | `:659-667` |
| `Everyone` + `!ViewerAllowsSensitiveMedia` + `ModernBlur` | blur `Violence` | `:627-636` |
| `Supported` + AgeVerification country + not verified | blur `Violence` + age prompt | `:648-657` |
| `IosNeedsUpdate` / `AndroidNeedsUpdate` + Tombstone country + not verified | Tombstone(UpdateApp*) | `:605-625` |
| `!ModernBlur` | legacy interstitial | `:638-646` |

**Gore has no `Unsupported → age_verification tombstone` branch** (only the two ios/android needs-update branches), so web / mac / third-party clients land on `legacy_interstitial` for gore (the `gore` dispatch table at `golden_corpus/age_verification.rs:139-153`). Corpus `:615-669`: **a viewer in fr / us who has turned the sensitive-media setting on is still blurred as long as the client has `GoreBlurIgnoresSettings`**; with that switch off it falls back to `gore_and_violence_high_precision/blur/age_prompt`; the author is allowed.

### 6.6 Propagation to quotes / reacted-to posts

`REACTED_TO_RULES` exists only at `TimelineHomeHydration` (`levels.rs:399`, `:479-483`), **not at the ads level**: `original_tweet_adult_media_propagation/blur/sensitive` (Everyone, `ReactedToPostHasLabel(NSFW_HIGH_PRECISION)`, `tweet_rules.rs:861-866`), `original_tweet_gore_media_propagation/blur/violence` (`:868-875`), `protected_original_author/drop` (`ReactedToAuthorIsProtected`, `:877-882`).

---

## 7. Age gating

### 7.1 The threshold and the three viewer-age states

**`ADULT_AGE_YEARS: i32 = 18`** (`viewer.rs:155`); `ViewerAge::{Known(i32), NotStated, Unknown}` with `#[default] Unknown` (`viewer.rs:158-163`). `is_underage()` = `Known(age) if age < 18` (`:192-194`); `has_no_stated_age()` = `== NotStated` (`:196-198`) → **`Unknown` (age could not be resolved) does not trigger the no-stated-age gate; only `NotStated` (explicitly not provided) does. Never conflate the two.** `ViewerAgeVerified` = **`age_verified_18 || profile.has_idv_premium`** (`rule_spec/features/compound.rs:69-73`) → **buying IDV Premium also counts as verified**; `age_verified_18` comes from `has_age_verified_18_label` (`rule_spec/features/viewer.rs:199-210`). `ViewerAllowsSensitiveMedia` = `profile.allows_sensitive_media` (`rule_spec/features/viewer.rs:59-61`).

### 7.2 The 9 hard DROPs (`AGE_GATING_DROPS`, `levels.rs:157-167`, all `NonAuthors`, evidence `tweet_rules.rs:294-380`)

| Rule | Condition | DropReason |
|---|---|---|
| `sensitive_viewer_logged_out/drop/media_label` | `ViewerLoggedOut && TweetHasMedia && HAS_NSFW_MEDIA_LABEL` | `NsfwViewerLoggedOut` |
| `sensitive_viewer_logged_out/drop/nsfw_flag` | `ViewerLoggedOut && TweetHasMedia && !TweetIsRetweet && IS_NSFW_FLAGGED` | same |
| `sensitive_viewer_logged_out/drop/text_or_card_label` | `ViewerLoggedOut && HAS_NSFW_TEXT_OR_CARD_LABEL` | same |
| `sensitive_viewer_underage/drop/*` ×3 | replace `ViewerLoggedOut` with `ViewerUnderage` | `NsfwViewerIsUnderage` |
| `sensitive_viewer_no_stated_age/drop/*` ×3 | `ViewerNoStatedAge && ViewerAccountOrRequestCountryIn(NsfwGating) && …` | `NsfwViewerHasNoStatedAge` |

The three named conditions (`rule_spec/conditions.rs`): `HAS_NSFW_MEDIA_LABEL` = `NSFW_HIGH_PRECISION | NSFW_HIGH_RECALL | GORE_AND_VIOLENCE_HIGH_PRECISION` (`:6-13`); `IS_NSFW_FLAGGED` = `AuthorIsNsfwUser | AuthorIsNsfwAdmin | TweetNsfwUserFlag | TweetNsfwAdminFlag` (`:15-23`); `HAS_NSFW_TEXT_OR_CARD_LABEL` = `NSFW_TEXT | NSFW_CARD_IMAGE` (`:25-31`).

### 7.3 Exemption boundaries (what the setting can and cannot bypass)

| Fact | Evidence |
|---|---|
| **Retweets are exempt from the nsfw_flag age gate** (`!TweetIsRetweet`); an nsfw-user-flagged media post that is retweeted → becomes a `SensitiveUser` blur | `tweet_rules.rs:307`, `:333`, `:365`; `golden_corpus/age_gating.rs:220-239` |
| **An underage author sees their own post allowed** (`NonAuthors`); **the sensitive-media setting cannot bypass the underage gate**: age 17 + opted in → still an `IsUnderage` drop | `golden_corpus/age_gating.rs:32-137` |
| **`no_stated_age` only applies in the 16 `NsfwGating` countries**: requests from gb / de are dropped, a kr account + us request is dropped; a us request, a us account + de request, no country, or `Unknown` age in gb → allowed on `TimelineHome` | same |
| **`LoggedOut` is dropped unconditionally, regardless of country** | `tweet_rules.rs:294-318` |
| The setting only exempts blurs (`ViewerAllowsSensitiveMedia`); it **cannot exempt** the underage / logged-out / no-stated-age hard DROPs, gore's `IgnoringSettings`, or India's `LocalRegulations` | `tweet_rules.rs:462`, `:473`, `:591`, `:674`, `:754`, `:785`, `:659-667`, `:485-493` |

---

## 8. Legal takedowns: `xx` / `xy` and three country granularities

### 8.1 The two worldwide codes and the two extractors

`tweet.rs:101-107`: `WORLDWIDE_COUNTRY_CODE = "xx"`, `WORLDWIDE_COPYRIGHT_COUNTRY_CODE = "xy"`; `is_worldwide_code(c)` is case-insensitive. The matching logic `takedown_in()` = `is_worldwide_code(c) || request_country.eq_ignore_ascii_case(c)` (`tweet.rs:82-90`).

| TakedownReason | `legal_takedown_country()` (`tweet.rs:109-124`) | `local_laws_takedown_country()` (`tweet.rs:126-139`) |
|---|---|---|
| `LegalRequest{"xy"}` | **`None`** — **worldwide copyright requests are not enforced by legal_takedown** | `None` |
| `LegalRequest{cc}` / `UnspecifiedReason{cc}` | `Some(cc)`; `cc=="xx"` → worldwide drop, otherwise match the request country | `None` |
| `Dmca` | `Some("xy")` → `is_worldwide_code("xy")` → **worldwide drop** | `None` |
| `BystanderReport{cc}` where cc is not xx/xy | `None` | `Some(cc)` → dropped in that country only |
| `BystanderReport{"xx"\|"xy"}` | `None` | **`None` (a worldwide bystander report is not enforced by local laws)** |
| `HatefulImagery` / `SensitiveImagery` / `Unknown` | `None` | `None` |

**Both rules have audience `NonAuthors`** (`tweet_rules.rs:246`, `:253`) → **the author always sees their own taken-down post.**

### 8.2 Golden corpus (`golden_corpus/takedown.rs`)

| Scenario | Result | Lines |
|---|---|---|
| `LegalRequest{"us"}`, request country us / fr | DROP / **allow** | `:11-33` |
| `LegalRequest{"xx"}` / `{"xy"}` | worldwide DROP / **allow** (copyright is not geo-enforced) | `:34-50`, `:51-58` |
| `UnspecifiedReason{"xx"}` / `{"xy"}` | **both DROP** | `:59-86` |
| `BystanderReport{"xx"}`; `HatefulImagery` + `Unknown` | **allow** | `:87-94`, `:140-147` |
| `TakedownReason::Dmca` | NonFollower DROP, Author allow | `:95-109` |
| `BystanderReport{"de"}`, request country de | DROP via `local_laws_takedown`; **account country de but request from elsewhere → allow** | `:110-139` |
| Uppercase `"XX"` / `"XY"` | DROP (case-insensitive) / allow | `:148-164`, `:165-192` |

### 8.3 Three country granularities — keep them apart

| Granularity | Semantics | Used by | Evidence |
|---|---|---|---|
| `RequestCountryIs("br")` / `RequestCountryIn(list)` | **request country only** (IP / request context), never the account country | `brazil_election_legal`, every tombstone / age_verification condition | `tweet_rules.rs:956`; `rule_spec/conditions.rs:90`, `:98` |
| `ViewerAccountOrRequestCountryIn(list)` | **account country first, falling back to the request country only when it is missing** | the three `sensitive_viewer_no_stated_age` rules | `rule_spec.rs:799-808`; `tweet_rules.rs:351`, `:363`, `:376` |
| Media geo allow / deny | `country = request_country.unwrap_or("xx")`; `(!allow.is_empty() && !allow.contains(country)) \|\| deny.contains(country)`, case-insensitive | `geo_restricted_media/drop` | `tweet.rs:92-98` |

**With no request country, media geo treats it as `"xx"`, so a non-empty allow-list almost always drops.** Media geo lists **do not expand region codes** — the `AFR / AUS / CAS / EAS / EUR / NAM / SAM / SAS / SEA / WES` expansion function `allows_country()` in `models/region.rs` (`region.rs:61-71`) is called only by `ViewerIsInAllowedCountry` (the reply-control country whitelist) (`rule_spec/features/compound.rs:87-93`), and has nothing to do with media geo.

### 8.4 Upstream Scala: account-level takedowns are merged into post-level ones

- `takedowns/tweet-entity-service/TakedownReasonsTransform.scala:52-69`: when `tweetFields.hasTakedown == true`, `combinedTakedownReasons = tweetTakedownReasons ++ userTakedownReasons`, while preserving `tweetypieOnlyTakedownReasons`. User-level takedowns come from Gizmoduck `QueryFields.Takedowns` (`:19-34`). → **An account-level takedown makes every post by that account carry a takedown reason.** Field names `takedownReasons` / `TweetFieldKeyType.TakedownReasons` (`takedowns/tweet-entity-service/TakedownReasonsColumn.scala:18-25`).
- `takedowns/gizmoduck/RedactUnenforcedTakedownsFilter.scala:64-81`: a read-side filter (gated by `enableReadGate`, `:43`) strips **unenforced** takedowns from the user object: `UnspecifiedReason("xy")`, `LegalRequest("xy")`, `BystanderReport("xx"|"xy")` and `Dmca` are all redacted (`:68-78`), counted as `redacted_unenforced_takedowns` (`:24`). It sits at the end of the filter chain in `ReadFilters.scala:37`.

---

## 9. Shown but limited: `LimitedEngagement`

### 9.1 Do not conflate the three kinds of "restriction"

**`LimitedEngagement` (severity 6)** = the post is shown normally, certain buttons are disabled; **FOSNR (Freedom of Speech, Not Reach)** = strangers DROP, followers get a soft intervention, the author gets appealable + limits; **a `NonFollowers` audience DROP** = de facto "not recommended but visible to followers". **This subsystem has no "downrank" tier.** home-mixer's `BrandSafetyVerdict{Unspecified=0, Safe=1, LowRisk=2, MediumRisk=3, HighRisk=4}` (`home-mixer/models/brand_safety.rs:7-14`) is an **ads-adjacency** grade (`home-mixer/ads/neighbours.rs`), not an organic-reach downrank.

### 9.2 The 14 reasons × the actions they actually disable

`LimitedEngagementReason` has 14 values (`verdict.rs:218-233`), external strings at `:236-253`. `LimitedActionType` has 26 disableable actions (`verdict.rs:51-78`, wire mapping `thrift.rs:416-447`): `Reply, Retweet, QuoteTweet, Like, React, SendViaDm, AddToBookmarks, AddToMoment, PinToProfile, ViewTweetActivity, ShareTweetVia, Follow, ListsAddRemove, MuteConversation, Embed, ViewHiddenReplies, HideCommunityTweet, CopyLink, VoteOnPoll, RemoveFromCommunity, ShowRetweetActionMenu, ReplyDownVote, Autoplay, EditTweet, Highlight, ViewPostEngagements`.

The policy file `../../visibility-limited-actions/main/limited_actions_policy.yml` (`params.rs:36-37`) **is not in the repo**. The effective table is pinned by the test `each_reason_resolves_its_policy_from_the_scala_file` (`limited_actions_policy.rs:167-363`):

| Reason | copy namespace | Disabled actions | Evidence |
|---|---|---|---|
| `NonCompliant` | `NonCompliant` | **11 actions** | `limited_actions_policy.rs:197-213` |
| `ConversationControl` | `LimitedReplies` | `[Reply]` | `:214` |
| `BlockedViewer` | `BlockedViewer` | **19 actions** | `:215-239` |
| `RootAuthorBlockedViewer` | `BlockedViewer` | `[Reply]` | `:240-244` |
| `ReadonlyViewer` | `ReadonlyViewer` | **14 actions** | `:245-264` |
| `StaleTweet` | **no copy** | **15 actions** | `:265-285` |
| `CommunityTweetHidden` | `CommunityHidden` | `community_unavailable` minus `RemoveFromCommunity` = **18 actions** | `:286-290`, `:170-190` |
| `CommunityTweetMemberRemoved` / `NotFound` / `Suspended`; `CommunityTweetCommunityDeleted`; `CommunityTweetViewerRemoved` | `Default`; `Default`; `ViewerIsRemovedFromCommunity` | respectively: `community_unavailable` **19 actions**; `[HideCommunityTweet, RemoveFromCommunity]`; `[Reply, PinToProfile]` | `:291-310`, `:170-190`; `:301-305`; `:311-315` |
| `DynamicProductAd` | **no copy** | **8 actions** | `:316-329` |
| `LocalTweet` | `LocalPost` | `[Retweet, Reply]` | `:330` |

### 9.3 The two FOSNR limit tiers

- **level 3** (`FOSNR_ABUSE / CIVIC_INTEGRITY / HATEFUL_CONDUCT / VIOLENT_SPEECH`) → `AUTHOR_LEVEL_3_LIMITED_ACTIONS`, **13 actions**: `Like, Reply, Retweet, QuoteTweet, ShareTweetVia, AddToBookmarks, PinToProfile, CopyLink, SendViaDm, EditTweet, Highlight, Embed, ListsAddRemove` (`tweet_rules.rs:89-106`). **level 1** (`FOSNR_ABUSE_INSULTS`) → **only `[EditTweet]`** (`tweet_rules.rs:133-138`).
- On the wire, `limited_engagements.reason` = `(reason.level != 1).then(|| "freedom_of_speech_not_reach")` (`thrift.rs:250`) → **level 1 carries no FOSNR marker**. The soft-intervention wire shape is `engagement_nudge=false, suppress_autoplay=true, display_type=FOSNR, warning=None, details_url=None` (`thrift.rs:254-265`) → **what a follower sees is "autoplay suppressed + a FOSNR notice", not a hard block**. Both `Appealable` and `SoftIntervention` carry `Avoid{brand_safety_risk_level: NORMAL}` (`thrift.rs:212-214`).

### 9.4 User-facing copy

The copy bundle `/config/stringcenter/visibility-ltd-actions.json` (`limited_actions_copy.rs:10`) is **not public**. Mechanism: key = `{namespace}_{Action}_Headline` / `_Subtext`; `{namespace}_GenericSubtext` is **shared only by `BlockedViewer` and `ReadonlyViewer`** (`:14`, `:99-140`). `PromptKind::{Basic, SeeConversation, LearnMore{link_text, url}}` (`:35-42`) is decided by the switches `limited_actions_policy_copy_namespace` / `_prompt_type` / `_prompt_learn_more_url`: `"NoCopy"` → no copy, `"cta"` → SeeConversation, a url present → LearnMore (`:157-177`). The placeholder is `learnmore` (`:16`), on the wire `LEARN_MORE_PLACEHOLDER` (`thrift.rs:286`, `:303`, `:405`).

**Only the EN/JA fragments inside the test BUNDLE are visible real strings** (`limited_actions_copy.rs:228-247`): `"Who can reply?"` / `"Only some accounts can reply."` / ja「一部のアカウントのみが返信できます。」; `"Why can't you like this?"`; `"This author has blocked you, so you can't perform this action"`; `"You cannot reply"` / `"You cannot reply this post"`. For public-interest interstitials only the resnames are public (`thrift.rs:314-356`): `public_interest.*` (`.episodic / .self_harm / .hateful_conduct / .gratuitous_gore / .glorifying_violence / .mob_harassment / .moment_of_death / .private_information / .right_to_privacy / .threat_to_expose / .violent_sexual_conduct / .violent_threat / .voting_misinformation / .hacked_materials / .scams / .platform_manipulation / .one_off`), `misinfo.civic / .crisis / .generic / .medical`, `fosnr.abusive_behavior / .civic_integrity / .hateful_conduct / .violent_speech / .synthetic_and_manipulated_media`. Links: `MISINFO_CIVIC→links::ELECTION_INTEGRITY`, `MISINFO_CRISIS→links::CRISIS_MISINFORMATION`, `MISINFO_GENERIC→links::TWITTER_RULES`, everything else `links::PUBLIC_INTEREST` (`:349-354`). **The translations are not public** (they go through `graphql_results::translate`).

---

## 10. The exemption list, and the most important negative result

### 10.1 Submitting an appeal **changes no visibility verdict**

`FOSNR_APPEAL_SUBMITTED` **only affects the `FosnrReason.appeal_submitted` boolean** (`rule_spec.rs:675`), which in turn only affects the emitted `AppealableReason` (`thrift.rs:216-223`). **No rule's `when` reads `FOSNR_APPEAL_SUBMITTED`**: the condition side only has `HAS_FOSNR_LABEL`, which lists the 5 violation labels and not the appeal label (`rule_spec/conditions.rs:75-84`). `appeal()` merely "finds the first matching violation → builds a Notice", with no exemption branch at all (`rule_spec.rs:655-663`). **Pinned by the golden corpus**: `golden_corpus/oon_tweet_label.rs:197-226` (`fosnr_abuse_insults_by_agent_under_appeal`) — adding `with_agent_label` + `FOSNR_APPEAL_SUBMITTED` yields `proactive=false, appeal_submitted=true`, **but the verdict is completely unchanged**: strangers still drop, followers still get soft_intervention, the author is still appealable.

**Conclusion: appeal status inside visibility-filtering is purely display-layer information (it lets the client show "appealed"). Actual relief must come from the upstream label being revoked. There is no "appeal succeeded → skip the rule" bypass anywhere in the repo.**

### 10.2 The exemptions that do exist

| Exemption | Condition | Evidence |
|---|---|---|
| Author self-exemption | every `NonAuthors` / `NonFollowers` rule | `rule_spec/engine.rs:67-68` |
| Follower exemption | every `NonFollowers` rule (§4.2); for `fosnr_abuse_insults` followers are not fully exempt but downgraded to soft_intervention | `tweet_rules.rs:186-199` |
| Community moderator / author exemption | community-related drops do not apply to moderators or the author | `tweet_rules.rs:1181-1232` (tests); `mod.rs:204` |
| Conversation root author / invited viewer exempt from reply control | `VIEWER_IS_NEITHER_ROOT_AUTHOR_NOR_INVITED` | `rule_spec/conditions.rs:101-108`; `tweet_rules.rs:1050-1138` |
| Super Follows exempts exclusive content; Trusted Friends list member / owner exemption | `ViewerSuperFollowsAuthor`; `ViewerIsTrustedFriendsListMemberOrOwner` | `rule_spec/features/compound.rs:74-78`; `tweet_rules.rs:409`, `:421`, `:444-452` |
| Retweets exempt from the nsfw-flag age gate / reply control / nullcast | `!TweetIsRetweet` | `tweet_rules.rs:307`, `:333`, `:365`, `:1120`, `:1133`, `:218` |
| Age-verified / IDV Premium exempts tombstone + age prompt | `ViewerAgeVerified` | `rule_spec/features/compound.rs:69-73`; `golden_corpus/age_verification.rs:163-233` |
| Account country ≠ request country | tombstones look only at the request country | `rule_spec/conditions.rs:90`, `:98`; `golden_corpus/takedown.rs:110-139` |
| Old-client degradation | `!ClientHas(FosnrRules)` → FOSNR rules do not apply at all; with `FosnrFallbackDrops` on they become outright DROPs; `!ModernBlur` gets the legacy interstitial instead of a blur | `tweet_rules.rs:181`, `:192`, `:204`, `:211`, `:576-584`, `:638-646`, `:741-749`, `:849-859` |
| Logged-out viewers skip viewer-related hydrators | `policy.hydrators.without_viewer()` | `engine.rs:750-756` |
| fail-open defaults | `Truth::Unknown{default, failed}` (`rule_spec.rs:584-652`); `Defaults{withholding, media, engagement}` (`defaults.rs:57-99`); a `must_have()` failure → `Partial` → RPC `Failed` | `engine.rs:250-254`, `:189-221`; `rpc.rs:86` |
| **Experiment skipping: does not exist in production** | `Effect::SkippedByExperiment` (`engine.rs:146-173`) exists, but `Experiment` only has `#[cfg(test)] TestLaunch / TestHoldback` (`experiment.rs:6-11`), and the comment explicitly says "no experiment is wired yet" (`:16-19`) | same |

---

## 11. Explicit "not public" list

| Missing artifact | Referenced at | Impact |
|---|---|---|
| `visibility-filtering/docs/policy-catalog.md`, `GLOSSARY.md` (Slot semantics) | `catalog.rs:172`, `:74-85` | the official rule catalog is absent; the ordering tables here are reconstructed from `action_kind.rs` + `engine.rs` |
| The authoritative `SafetyLabelType` IDL enum + numeric IDs | `safety_labels.rs:1` (external crate `xai_x_thrift`) | only the 53 variants referenced in the repo can be listed |
| Full enums for `FilteredReason` / `InterstitialReason` / `AppealablePolicy` / `SafetyResultReason` / `TakedownReason` / `ConversationControlArm` | all from external crates | same |
| The 7 feature-switch YAMLs (`age_verification.yml` etc.) + `limited_actions_policy.yml` | `params.rs:26-37` | effective values can only be reverse-engineered from pinned tests (§9.2); the same applies to country lists and the client capability matrix |
| `tests/fixtures/scala_client_switches.yml`, `tests/fixtures/limited_actions_policy.yml` | `client_switches.rs:105-108` | **the `visibility-filtering/tests/` directory does not exist**, confirmed |
| The StringCenter bundle `/config/stringcenter/visibility-ltd-actions.json` + interstitial resname translations | `limited_actions_copy.rs:10`; `thrift.rs:314-356` goes through `translate()` | real copy exists only as the EN/JA fragments in the test BUNDLE; interstitials have keys only |
| Production experiment configuration | `experiment.rs:6-11` | no experiment is wired in production |
| Visibility rules for the Search / Profile / Explore surfaces | `SafetyLevel` has only 9 values (`safety_level.rs:23-33`) | "not recommended but searchable" and "profile-only" have no tier in this subsystem |
| The organic-reach downrank weight formula | not in visibility-filtering | see `02-scoring-ranking` |

---

## 12. Diagnostic quick reference

| Symptom | Where to look first |
|---|---|
| "Followers see it, strangers don't" | the `NonFollowers` list (§4.2): the `DO_NOT_AMPLIFY` / `MALICIOUS_URL` post labels, the `AbusiveHighRecall` / `DoNotAmplify` author labels, `protected_author` |
| "It's in Following but not in For You" | the 26-rule delta in §3.4; for adult / violent content see §6.1 |
| "The API says allow but the app shows a warning" | §1.2 vs §1.3: `filter_tweets` flattens FOSNR / interstitials / limits into ALLOW |
| "My reply never notified the other person" | §4.3: `RISKY_HIGH_VIZ_REPLY` / `DOWNRANK_SPAM_REPLY` / the UQF family only suppress notifications |
| "The post became a tombstone" / "the image is blurred and the setting doesn't help" | §6.4: request country ∈ the 30 countries + client `Unsupported`/needs-update + not age-verified; §6.5 gore + `GoreBlurIgnoresSettings`; §6.2 India's `LocalRegulations` |
| "I appealed and nothing came back" / "I can see it but nobody else can" | §10.1: an appeal only changes a display bit, the upstream label must be revoked; almost every Drop is `NonAuthors`, so the author is always exempt |