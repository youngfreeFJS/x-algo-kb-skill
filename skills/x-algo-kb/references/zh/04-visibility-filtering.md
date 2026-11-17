# 04 · 可见性过滤：一条帖能不能给你看

> 证据基准：`xai-org/x-algorithm` @ `a284320b66a9dce35e6f5d6b052ee308eeb12326`，逐条只读核对。
> 路径缩写（相对仓库根）：`tweet_rules.rs` / `author_rules.rs` / `levels.rs` / `engine.rs` / `action_kind.rs` / `safety_level.rs` / `catalog.rs` / `fixtures.rs` / `defaults.rs` / `experiment.rs` / `rule_spec.rs` = `visibility-filtering/rules/<file>`；`rule_spec/<file>` = `visibility-filtering/rules/rule_spec/<file>`；`golden_corpus/<file>` = `visibility-filtering/rules/golden_corpus/<file>`。
> `verdict.rs` / `viewer.rs` / `tweet.rs` / `author.rs` / `region.rs` / `safety_labels.rs` / `mod.rs` = `visibility-filtering/models/<file>`；`proto.rs` / `thrift.rs` / `rpc.rs` = `visibility-filtering/treatment/<file>`。
> `params.rs` = `visibility-filtering/params.rs`；`client_switches.rs` / `limited_actions_policy.rs` / `limited_actions_copy.rs` = `visibility-filtering/params/<file>`。

**本子系统只判定「能不能看、看到什么形态」，不打分、不降权。** 权重公式见 `02-scoring-ranking`（`xai-value-model` / `vm-ranker`），候选能不能进池子见 `03-retrieval-filtering`（`home-mixer`）。

`visibility-filtering/docs/policy-catalog.md` 与 `GLOSSARY.md` **在仓库中不存在**。`catalog.rs` 是文档生成器而非注册表（`catalog.rs:23-46`、`:170-173`）；**真正的注册表是 `levels.rs`（每个 level 的规则清单）+ `safety_level.rs`（level → 清单绑定）**。本文所有顺序表由 `action_kind.rs` + `engine.rs` + `levels.rs` 重建。

---

## 1. 两套系统、三个 RPC 面

### 1.1 内部三态，对外八种

内部 `Verdict` 三态（`verdict.rs:21-29`）：`Withheld(Drop(DropReason) | Tombstone(TombstoneReason))`、`Fosnr(Notice::SoftIntervention(FosnrReason) | Notice::Appealable{reason, limited_actions})`、`Shown{label_interstitial, media, engagement}`（三个 `Option` 槽）。对外 `VerdictAction` 8 值（`verdict.rs:9-18`）：`Allow / Drop / Tombstone / Interstitial / LimitedEngagement / TweetInterstitial / SoftIntervention / Appealable`。

### 1.2 `filter_tweets`（召回 / 粗排侧，proto）只输出 3 种结果

`proto.rs:5-37`，封装在 `rpc.rs:49-57`：

| 内部 Verdict | proto `Action.kind` | `filtered_reason` |
|---|---|---|
| `Withheld(Drop(reason))` | `Drop` | `reason.legacy()` |
| `Withheld(Tombstone(_))` | **`Drop`** | `UnspecifiedReason`（tombstone 被压成 drop） |
| `Shown{ media: Some(_), .. }` | `Interstitial(true)` | `ContainNsfwMedia` |
| **`Fosnr(_)`（notice / appealable / soft intervention）** | **`Allow(true)`** | `None` |
| `Shown{ media: None, .. }`（只有插屏 / 只有限权） | **`Allow(true)`** | `None` |

**最容易踩的坑：在 `filter_tweets` 面上，FOSNR notice、公共利益插屏、互动限权全部被当成 ALLOW 放行，Tombstone 被当成普通 Drop。** 只有「媒体遮挡」会变成 INTERSTITIAL。所以「接口说 allow，App 里却显示警告」不是 bug，是两个面语义不同。该面只服务 4 个 level：`FilterAll / TimelineHome / TimelineHomeRecommendations / ImmersiveExpandedRecommendations`（pinned 测试 `safety_level.rs:313-341`）。

### 1.3 `evaluate_tweets`（渲染 / hydration 侧，thrift）暴露全部 8 种

`thrift.rs:30-174`：

| 内部 Verdict | thrift 落地 | 行号 |
|---|---|---|
| `Withheld(Drop)` | `TweetFieldsResultState::Filtered` | `:43-51` |
| `Withheld(Tombstone)` | `Filtered` + `Action::Tombstone` | `:52-58` |
| `Fosnr(SoftIntervention)` | **`Found`** + `TweetInterstitial{soft_intervention, avoid}` | `:59-69` |
| `Fosnr(Appealable)` | **`Found`** + `TweetInterstitial{limited_engagements, avoid, appealable}` | `:70-85` |
| `Shown` 有 label_interstitial | `Found` + `TweetInterstitial{interstitial, limited_engagements, media_action, all_media_visibility_results}` | `:86-124` |
| `Shown` 三槽全空 | `Found(None)` = 纯 ALLOW | `:125-129` |

`verdict_action()` 归并（`rpc.rs:14-35`）：三槽全空 = `Allow`；只有 media = `Interstitial`；只有 engagement = `LimitedEngagement`；**其余任意组合 = `TweetInterstitial`**。该面只服务 5 个 thrift level：8 / 16 / 61 / 82 / 124（`safety_level.rs:344-370`）；`ImmersiveExpandedRecommendations` 的 `evaluate_tweets` 是 `None`（`safety_level.rs:156-162`）——**沉浸式视频流只走召回面，不走渲染面**。

### 1.4 通知面是第三套语义；失败 / 缺失态

`rpc.rs:115-120`：`Verdict::Fosnr(_) | Verdict::Shown{..}` 一律 `Outcome::Allowed`，只有 `Withheld` 才 `Dropped`；**且要求 `fail_open_defaults.is_empty()`，否则整体 `Outcome::Failed`**（`rpc.rs:115`、`:127-128`）。drop reason 只映射 4 条规则（`rpc.rs:138-155`）：`SuspendedAuthor→ActorSuspended`、`ProtectedAuthor→ActorProtected`、`ViewerBlocksAuthor→RecipientBlocksActor`、`ViewerMutesAndDoesNotFollowAuthor→RecipientMutesActor`，其余全部 `Unspecified`。

`Evaluation::{Complete, Partial, NotFound, Deleted, Failed}`（`verdict.rs:340-352`）。`Partial` 当且仅当失败的 hydrator 命中 `must_have()`（`engine.rs:189-221`）。`evaluate_tweets_state` 对 `Partial | Failed` 返回 `None` → `Outcome::Failed`（`rpc.rs:86`、`:69`）；`Deleted` → `NotFound(deleted=true, bounce_deleted=...)`（`rpc.rs:83-85`）。

---

## 2. severity fold：唯一的优先级表

### 2.1 七种 `ActionKind`（`action_kind.rs:5-13`，属性 `:59-130`）

| ActionKind | severity | Lands | kept_by（被谁抢占） | Bucket | VerdictAction | 行号 |
|---|---|---|---|---|---|---|
| `Appealable` | **18** | `Fosnr` | `&[]` | Withholding | Appealable | `:59-67` |
| `Drop` | **17** | `Withheld` | `&[]` | Withholding | Drop | `:68-76` |
| `Tombstone` | **16** | `Withheld` | `&[]` | Withholding | Tombstone | `:77-85` |
| `LabelInterstitial` | **11** | `Slot(LabelInterstitial)` | `[(LabelInterstitial, KeptEarlierLabelInterstitial)]` | Media | Interstitial | `:86-97` |
| `MediaRestriction` | **10** | `Slot(Media)` | `[(Media, KeptEarlierMedia)]` | Media | Interstitial | `:98-106` |
| `SoftIntervention` | **8** | `Fosnr` | `[(LabelInterstitial, KeptEarlierLabelInterstitial), (Media, KeptEarlierMediaInsteadOfFosnr)]` | Media | SoftIntervention | `:107-121` |
| `LimitedEngagement` | **6** | `Slot(Engagement)` | `&[]` | Engagement | LimitedEngagement | `:122-130` |

`ends_the_fold()`：`Lands::Withheld | Lands::Fosnr => true`，`Lands::Slot(_) => false`（`action_kind.rs:163-168`）。

### 2.2 fold 算法（`engine.rs`）

1. **排序** `rules.sort_by_key(|(_, rule, _)| Reverse(rule.action.spec().kind().severity()))`（`:51`）。Rust 稳定排序 → **同 severity 内保持 `levels.rs` 的书写顺序**。
2. **user 列表先折、post 列表后折**；`gate()` 里若 `user.terminal.is_some()`，**整个 post 列表被跳过**（`:365-377`）。
3. **短路** `let after = terminal.is_some(); if after && !O::TOTAL { break; }`（`:124-127`）。生产 observer 非 TOTAL → **第一条命中的 Drop / Tombstone / Appealable / SoftIntervention 直接结束评估**。
4. **抢占** `completed = truth.resolves_true() && (!after && action.kind().kept_by(decision.filled()).is_none())`（`:133-135`）；`step()` 里 `if let Some(effect) = kind.kept_by(filled) { return (None, effect, reads) }`（`:258-260`）。
5. **落槽**（`:261-299`）：`Withholding` → `Verdict::Withheld` + `Decided`（终止）；`Notice` → `Verdict::Fosnr` + `Decided`（终止）；`LabelInterstitial` / `Media` → 填槽后**继续**；`Engagement` → 首次 `FilledEngagement`，之后 `limit.add(reason)` 累加去重（`:279-298`）。未终止则 `finish()` → `Verdict::Shown{...}`（`:303-309`）。
6. 同一 rule name 不许同时出现在 user 与 post 列表（`:334-339`），也不许在同一 level 重复接线（`:52-62`）。

### 2.3 「notice 和 interstitial 同时命中怎么办」

| 组合 | 结果 | 证据 |
|---|---|---|
| `Appealable`(18) + 任何插屏 / 遮挡 | **Appealable 永远赢**，kept_by 为空 → `Verdict::Fosnr(Appealable)`，插屏与遮挡全不生效 | `action_kind.rs:59-67` |
| FOSNR 的 `Drop`(17) 版本 + 插屏(11) / 遮挡(10) | **直接 DROP 终止**，插屏没机会 | `action_kind.rs:68-76` |
| `SoftIntervention`(8) + 已填的插屏(11) 或遮挡(10) | **soft intervention 被丢弃**（`KeptEarlierMediaInsteadOfFosnr` / `KeptEarlierLabelInterstitial`），fold 继续 | `action_kind.rs:107-121`；`golden_corpus/oon_tweet_label.rs:227-249`（`fosnr_abuse_insults_on_nsfw_media` → 只剩 `nsfw_high_precision/blur/sensitive`） |
| `LabelInterstitial`(11) + `MediaRestriction`(10) | **两个不同的槽，可叠加共存** → `VerdictAction::TweetInterstitial`，thrift 同时下发 `interstitial` + `media_action` / `all_media_visibility_results` | `rpc.rs:33`；`thrift.rs:114-123` |
| `LimitedEngagement`(6) + 任何槽 | **永远可叠加**，多 reason 累加去重，下发时按 action_type 再去重 | `engine.rs:279-298`；`thrift.rs:366-379`；`golden_corpus/relationship.rs:64-83`、`:102-121` |

### 2.4 两条编译期 invariant

- `a_less_severe_action_kind_never_relies_on_an_earlier_defaults_bucket`（`rule_spec/laws.rs:640-647`）：保证 `Withholding < Media < Engagement`（`defaults.rs:40-44`），低严重度动作不会依赖高严重度桶的 fail-open 默认值。
- `a_user_rule_that_ends_the_fold_never_shadows_a_more_severe_post_rule`（`rule_spec/laws.rs:649-685`）：user 列表先折，所以任何会终止 fold 的 user 规则，其 audience 必须与所有更高 severity 的 post 规则**不相交**（只有 `OnlyAuthor` vs `NonAuthors/NonFollowers` 算不相交）。这解释了为什么 `fosnr_author/appealable`(18, `OnlyAuthor`) 只接在 Hydration 层——该层 user 列表全是 `NonAuthors/NonFollowers`（`levels.rs:384-391`）。

---

## 3. For You 比 Following 多 26 条 Drop

### 3.1 九个 level 与 wire 号（`safety_level.rs:23-33`；号由 pinned 测试 `:383-401` 钉死）

| SafetyLevel | thrift | `filter_tweets` | `evaluate_tweets` | 规则清单 |
|---|---|---|---|---|
| `FilterAll` | 16 | 是 | 是 | `levels.rs:313-316` |
| `TimelineHome`（Following） | **8** | 是 | 是 | `levels.rs:318-336` |
| `TimelineHomeRecommendations`（For You） | **61** | 是 | 是 | `levels.rs:338-381` |
| `TimelineHomeHydration`（渲染） | **82** | 否 | 是 | `levels.rs:383-402` |
| `TimelineHomePromotedHydration`（广告） | 124 | 否 | 是 | `levels.rs:404-415` |
| `ImmersiveExpandedRecommendations` | — | 是 | **否** | `levels.rs:485-510` |
| `QuotedTweetRules` | — | 否 | 否（引用内层校验） | `levels.rs:222-231` |
| `NotificationsFollow` | 246 | 否 | 否（通知面） | `levels.rs:301-311` |
| `NotificationsWriterV2` | 72 | 否 | 否（通知面） | `levels.rs:233-299` |

**没有 Search / Profile / Explore 级别。**「不推荐但可搜索」「仅主页可见」在本子系统没有对应档位，由别的服务决定，未公开。

### 3.2 For You 第一阶段：user 列表 20 条，全部 Drop(17)，按书写序

| rule_name | audience | 触发条件 | 证据 |
|---|---|---|---|
| `suspended_author/drop`、`deactivated_author/drop`、`erased_author/drop`、`offboarded_author/drop` | NonAuthors | `AuthorIsSuspended` / `AuthorIsDeactivated` / `AuthorIsErased` / `AuthorIsOffboarded` → `AuthorAccountIsInactive` | `author_rules.rs:7-12`、`:14-19`、`:21-33` |
| `protected_author/drop` | **NonFollowers** | `AuthorIsProtected` | `author_rules.rs:35-40` |
| `viewer_blocks_author/drop`、`viewer_mutes_author/drop` | Everyone | `!ViewerLoggedOut && ViewerBlocksAuthor` / `ViewerMutesAuthor` | `author_rules.rs:42-47`、`:49-54` |
| `nsfw_user_author/drop/nsfw_media`、`nsfw_admin_author/drop/nsfw_media` | NonAuthors | `AuthorIsNsfwUser` / `AuthorIsNsfwAdmin` → `ContainNsfwMedia` | `author_rules.rs:155-167` |
| `nsfw_{high_recall,high_precision,avatar_image,banner_image,near_perfect}_user_label/drop/unspecified` ×5 | NonAuthors | `AuthorHasLabel(同名 AuthorLabel)` | `author_rules.rs:169-202` |
| `{spam_high_recall,compromised,read_only,impersonation_high_precision}_user_label/drop/unspecified` ×4 | NonAuthors | `AuthorHasLabel(同名)` | `author_rules.rs:204-230` |
| `abusive_high_recall_user_label/drop/unspecified`、`do_not_amplify_user_label/drop/unspecified` | **NonFollowers** | `AuthorHasLabel(AbusiveHighRecall)` / `AuthorHasLabel(DoNotAmplify)` | `author_rules.rs:232-237`、`:239-244` |

接线来源：前 8 条 = `AUTHOR_STATE_DROPS` + `VIEWER_BLOCKS_OR_MUTES_AUTHOR_DROPS`（`levels.rs:90-99`、`:340-341`）；中间 7 条 NSFW = `levels.rs:342-350`；后 6 条 = `OON_AUTHOR_LABEL_DROPS`（`levels.rs:101-108`、`:351`）。

### 3.3 第二阶段：post 列表 40 条 Drop(17) + 6 条 blur(10)，按书写序

| rule_name | audience | 触发条件 | 证据 |
|---|---|---|---|
| `viewer_mutes_retweets/drop/unspecified` | Everyone | `!ViewerLoggedOut && TweetIsRetweet && ViewerMutesRetweetsFromAuthor` | `author_rules.rs:56-66` |
| `pdna/drop/nsfw_high_precision_safety_result`、`bounce/drop/bounced`、`spam/drop/undesirable` | NonAuthors | `PDNA` / `BOUNCE`→`TweetIsBounced` / `SPAM`→`PossiblyUndesirable` | `tweet_rules.rs:28-33`、`:35-40`、`:49-54` |
| `for_emergency_use_only/drop/unspecified` | Everyone | `FOR_EMERGENCY_USE_ONLY` | `tweet_rules.rs:56-61` |
| `fosnr_{hateful_conduct,violent_speech,abuse,civic_integrity}/drop/undesirable` ×4 | NonAuthors | 同名标签 | `tweet_rules.rs:141-167` |
| `nullcasted_tweet/drop`、`stale_tweet/drop/unspecified` | Everyone | `TweetIsNullcast && !TweetIsRetweet && !TweetIsCommunityTweet` / `TweetIsSupersededEdit && !IsQuotedInnerTweet && !TweetIsRetweet && !IsSourceTweet` | `tweet_rules.rs:215-220`、`:222-232` |
| `legal_takedown/drop/unspecified`、`local_laws_takedown/drop/unspecified` | NonAuthors | `TweetLegalTakedownInRequestCountry` / `TweetLocalLawsTakedownInRequestCountry`（§8） | `tweet_rules.rs:244-249`、`:251-256` |
| `sensitive_viewer_{logged_out,underage,no_stated_age}/drop/{media_label,nsfw_flag,text_or_card_label}` ×9 | NonAuthors | 见 §7 | `tweet_rules.rs:294-380` |
| `exclusive_tweet/drop/logged_out` / `/retweet` / `/non_super_follower` | Everyone / Everyone / NonAuthors | 均要求 `TweetHasExclusiveContent`，再分别加 `ViewerLoggedOut` / `TweetIsRetweet` / 无；后两者还要求 `!ViewerIsConversationAuthor && !ViewerSuperFollowsAuthor` | `tweet_rules.rs:396-401`、`:403-413`、`:415-424` |
| `trusted_friends_tweet/drop/unspecified` | NonAuthors | `TweetIsTrustedFriendsTweet && !ViewerIsTrustedFriendsListMemberOrOwner` | `tweet_rules.rs:444-452` |
| `geo_restricted_media/drop/unspecified`、`dmca_media/drop/unspecified` | NonAuthors / **Everyone** | `TweetMediaGeoRestrictedInRequestCountry` / `TweetHasDmcaMedia` | `tweet_rules.rs:891-896`、`:884-889` |
| `nsfw_user_tweet_flag/drop/nsfw_media`、`nsfw_admin_tweet_flag/drop/nsfw_media` | **Everyone** | `TweetNsfwUserFlag` / `TweetNsfwAdminFlag` | `tweet_rules.rs:898-903`、`:905-910` |
| `gore_and_violence_high_precision/drop/nsfw_media`、`nsfw_high_recall/drop/nsfw_media`、`nsfw_high_precision/drop/nsfw_media`、`nsfw_card_image/drop/nsfw_media` | NonAuthors | 同名标签 | `tweet_rules.rs:596-603`、`:912-918`、`:478-483`、`:679-684` |
| `soft_nsfw_new_user/drop/unspecified` | NonAuthors | `RequestHasSoftNsfwNewUserDrop && ViewerIsNewAccount && SOFT_NSFW` | `tweet_rules.rs:919-928` |
| `do_not_amplify/drop/undesirable`、`malicious_url/drop/undesirable` | **NonFollowers** | `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | `tweet_rules.rs:930-935`、`:937-942` |
| `spam_high_recall/drop/undesirable`、`brazil_election_legal/drop/undesirable`、`fosnr_abuse_insults/drop/undesirable` | NonAuthors | `SPAM_HIGH_RECALL` / `BRAZIL_ELECTION_LEGAL && RequestCountryIs("br")` / `FOSNR_ABUSE_INSULTS` | `tweet_rules.rs:944-949`、`:951-959`、`:169-174` |
| `HOME_BLURS` 6 条 `*/blur/*`（severity 10，排最后） | NonAuthors | 见 §6.1，**在推荐流全部被抢占** | `levels.rs:201-208`、`:367` |

分组来源 `levels.rs:354-379`。**`soft_nsfw_new_user` 三重门：DDG 开关 `soft_nsfw_tweet_label_new_user_rule_enabled` 缺省 `false`（`client_switches.rs:15`、`:141-147`），且「new user」指 `ViewerIsNewAccount`＝观众新号（`rule_spec/features/viewer.rs:73-75`），不是作者新号。代码在、默认关，不能用它解释真实触达问题。**

### 3.4 `TimelineHome`（Following，thrift 8）少掉的 26 条

`levels.rs:318-336`。pinned 测试 `timeline_home_recommendations_starts_with_timeline_home`（`levels.rs:550-556`）保证 **Recommendations 的清单以 Home 的清单为前缀**，差集恰好 26 条：

| 侧 | 少掉的规则 | 条数 |
|---|---|---|
| user | 7 条 NSFW 作者标记 / 作者标签 drop（`levels.rs:342-350`） | 7 |
| user | `OON_AUTHOR_LABEL_DROPS` 6 条（`levels.rs:101-108`） | 6 |
| post | `dmca_media/drop/unspecified`（`levels.rs:368`） | 1 |
| post | 7 条 NSFW 推文 flag / 标签 drop + `soft_nsfw_new_user`（`levels.rs:369-377`） | 7 |
| post | `OON_POST_DROPS` = `do_not_amplify` / `malicious_url` / `spam_high_recall` / `brazil_election_legal`（`levels.rs:215-220`） | 4 |
| post | `fosnr_abuse_insults/drop/undesirable`（`levels.rs:379`） | 1 |

**Following 保留 `HOME_BLURS` 6 条遮挡，且没有任何 NSFW Drop 抢在前面 → 同一条擦边内容在关注流是「模糊」，在推荐流是「消失」。** 黄金样例：同一条 `MALICIOUS_URL` 推文在 `TimelineHome` 上连陌生人都 allow（`golden_corpus/oon_tweet_label.rs:17-31`，`:30`）。

### 3.5 其余 level 的差异

- **`ImmersiveExpandedRecommendations`**（`levels.rs:485-510`）：有 `OON_AUTHOR_LABEL_DROPS` + `OON_POST_DROPS` + `MEDIA_TAKEDOWN_DROPS`(DMCA+geo) + gore drop，但**没有** `NSFW_HIGH_PRECISION_DROP` / `NSFW_CARD_IMAGE_DROP` / `NSFW_*_TWEET_FLAG_DROP`；改用 `nsfw_sensitive_viewer_tweet/drop/nsfw_media`（`!ViewerAllowsSensitiveMedia && IS_NSFW_SENSITIVE_TWEET`，`tweet_rules.rs:382-387`）与 user 侧 `nsfw_sensitive_viewer_user/drop/nsfw_media`（`:389-394`）。**开了敏感内容开关就能看**（`golden_corpus/age_gating.rs:138-180`）。
- **`TimelineHomePromotedHydration`**（广告，124）：user 列表**只有** `blocked_viewer/limited_engagement`；post 与 Hydration 一致但**去掉 `REACTED_TO_RULES`**（`levels.rs:404-415`）。
- **`FilterAll`**（16）：只有一条 `filter_all/drop/unspecified`（`when: all![]` 恒真，Everyone，`tweet_rules.rs:14-19`）→ **无条件全丢**；且是唯一 `unspecified_drop_is_exact: true` 的 level（`safety_level.rs:123`），使 `UnspecifiedReason` 落成精确的 `action::DropReason::Unspecified`（`thrift.rs:489-491`）。
- **`TimelineHomeHydration`**（82）才有完整 8 种判定：`fosnr_author/appealable`(18, OnlyAuthor, `tweet_rules.rs:201-206`) → 各 Drop(17) → 12 条 Tombstone(16) → `public_interest/label_interstitial` 与 `for_emergency_use_only/label_interstitial`(11) → 19 条 MediaRestriction(10) → `fosnr_abuse_insults_follower/soft_intervention/abuse`(8) → 14 条 LimitedEngagement(6)。清单 `levels.rs:383-402` + `HYDRATION_INJECTED_RULES:417-432` + `HYDRATION_MEDIA_AND_LIMITS:434-477`。
- **`for_emergency_use_only` 的两副面孔**：Drop 版本只接在 Home / Recommendations / Immersive（`levels.rs:326`、`:359`、`:498`），插屏版本只接在 Hydration / PromotedHydration（`levels.rs:431`）。**所以带该标签的帖进不了任何首页流，但被直接渲染时会出现动态紧急插屏**（`golden_corpus/label_interstitial.rs:185-213`）；source 以 `bot_id_` / `Abuse` / `hse` 开头或恰为 `["A","B","AB","OneOff","VotingMisinformation","HackedMaterials","Scams","PlatformManipulation"]` 之一时不生成插屏，直接 allow（`rule_spec.rs:767-785`；样例 `label_interstitial.rs:215-222`）。

---

## 4. `NonAuthors` vs `NonFollowers`：两条完全不同的分界线

### 4.1 精确定义（`rule_spec/engine.rs:67-68`，UserEngine 同值 `:98-99`）

```rust
NON_AUTHORS   = RuleCond::Not(&ViewerIsAuthor.leaf())
NON_FOLLOWERS = all![!ViewerIsAuthor, !ViewerFollowsAuthor]
```

`Audience` 四值 `Everyone / NonAuthors / NonFollowers / OnlyAuthor`（`rule_spec/rule.rs:100-105`，条件展开 `:108-115`）。**`NonAuthors` = 除作者本人外所有人（含粉丝）都丢，这是「作者豁免」不是「粉丝豁免」；`NonFollowers` = 作者本人 + 粉丝都放行、只丢陌生人，这才是真正的 OON 限流。** 所有 `sensitive_viewer_*`、`nsfw_*`、`legal_takedown`、`local_laws_takedown`、`fosnr_*_drop` 都是 `NonAuthors` → **作者永远看得到自己的违规推**。

### 4.2 `NonFollowers` 规则全清单

**user 侧 14 条：**

| rule_name | 条件 | 接入 level | 证据 |
|---|---|---|---|
| `protected_author/drop` | `AuthorIsProtected` | Home / Rec / Immersive / Hydration / 通知 | `author_rules.rs:35-40` |
| `abusive_high_recall_user_label/drop/unspecified` | `AuthorHasLabel(AbusiveHighRecall)` | Rec / Immersive / NotifWriterV2 | `author_rules.rs:232-237` |
| `do_not_amplify_user_label/drop/unspecified` | `AuthorHasLabel(DoNotAmplify)` | 同上 | `author_rules.rs:239-244` |
| `not_graduated_user_label/drop/unspecified`、`agatha_spam_top_user_user_label/drop/unspecified`、`engagement_spammer_user_label/drop/unspecified` | `AuthorHasLabel(NotGraduated)` / `(AgathaSpamTopUser)` / `(EngagementSpammer)` | 仅通知 | `author_rules.rs:246-251`、`:253-258`、`:260-265` |
| `blink_worst_user_label/drop/unspecified`、`downrank_spam_reply_user_label/drop/unspecified` | `AuthorHasLabel(BlinkWorst) && ViewerHasUqfEnabled && !ViewerHasBlinkLabel` / `AuthorHasLabel(DownrankSpamReply)` | 仅通知 | `author_rules.rs:267-276`、`:278-283` |
| `no_confirmed_email/drop/unspecified`、`no_confirmed_phone/drop/unspecified`、`no_default_profile_image/drop/unspecified` | `ViewerFiltersNoConfirmedEmail && !AuthorHasConfirmedEmail` / `ViewerFiltersNoConfirmedPhone && !AuthorHasVerifiedPhone` / `ViewerFiltersDefaultProfileImage && AuthorHasDefaultProfileImage` | 仅通知 | `author_rules.rs:110-115`、`:117-122`、`:124-132` |
| `no_new_users/drop/unspecified`、`no_not_followed_by/drop/unspecified`、`only_people_i_follow/drop/unspecified` | `ViewerFiltersNewUsers && AuthorIsNewAccount` / `ViewerFiltersNotFollowedBy && !AuthorFollowsViewer` / `ViewerMentionFilterIsFollowing` | 仅通知 | `author_rules.rs:134-139`、`:141-146`、`:148-153` |

另有 `quoted_viewer_mutes_author_not_following/drop`：声明 audience 是 `NonAuthors`，但 `when` 里带 `!ViewerFollowsAuthor`（`author_rules.rs:67-73`，接线 `levels.rs:229`）→ **效果等同粉丝豁免**，只用于引用内层校验。

**post 侧 10 条：**

| rule_name | 条件 | 接入 level | 证据 |
|---|---|---|---|
| `do_not_amplify/drop/undesirable`、`malicious_url/drop/undesirable` | `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | Rec / Immersive | `tweet_rules.rs:930-935`、`:937-942` |
| `fosnr_abuse_insults_non_follower/drop/undesirable` | `FOSNR_ABUSE_INSULTS && ClientHas(FosnrRules)` | Hydration / PromotedHydration | `tweet_rules.rs:176-184` |
| `spam_high_recall_oon/drop/undesirable` | `SPAM_HIGH_RECALL` | 仅 `NOTIFICATIONS_WRITER_V2_MEDIA_TAGGED`（`levels.rs:274`） | `tweet_rules.rs:1022-1027` |
| `risky_high_viz_reply_oon/drop/unspecified` | `RISKY_HIGH_VIZ_REPLY` | 仅通知 mention / reply / media_tagged（`levels.rs:259`、`:275`） | `tweet_rules.rs:1029-1034` |
| `duplicate_mention_uqf/drop/unspecified`、`abusive_uqf/drop/unspecified`、`untrusted_url_uqf/drop/unspecified`、`downrank_spam_reply_uqf/drop/unspecified` | `DUPLICATE_MENTION` / `ABUSIVE` / `UNTRUSTED_URL` / `DOWNRANK_SPAM_REPLY`，四条均 `&& ViewerHasUqfEnabled` | 仅通知（`LOW_QUALITY_AND_UQF_DROPS`） | `tweet_rules.rs:985-993`、`:995-1000`、`:1002-1010`、`:1012-1020` |
| `only_people_i_follow_outside_community/drop/unspecified` | `ViewerMentionFilterIsFollowing && !TweetIsCommunityTweet` | 仅通知 | `tweet_rules.rs:21-26` |

### 4.3 关键纠正：这些标签掐的是**通知**，不是 For You

`LOW_QUALITY_AND_UQF_DROPS`（`levels.rs:190-199`）与 `COMMUNITY_AND_SPAM_DROPS`（`levels.rs:181-188`）**已接线**，接入点是通知面：

| 常量 | 接线位置 | level |
|---|---|---|
| `COMMUNITY_AND_SPAM_DROPS` | `levels.rs:253`、`:292` | `NOTIFICATIONS_WRITER_V2_MENTION`、`NOTIFICATIONS_WRITER_V2_RETWEET_SOURCE` |
| `LOW_QUALITY_AND_UQF_DROPS` | `levels.rs:258`、`:297` | 同上两个 |
| `RISKY_HIGH_VIZ_REPLY_OON_DROP_UNSPECIFIED` | `levels.rs:259`、`:275` | `NOTIFICATIONS_WRITER_V2_MENTION`、`NOTIFICATIONS_WRITER_V2_MEDIA_TAGGED` |
| `SPAM_HIGH_RECALL_OON_DROP_UNDESIRABLE` | `levels.rs:274` | `NOTIFICATIONS_WRITER_V2_MEDIA_TAGGED` |

`NOTIFICATIONS_WRITER_V2_REPLY = NOTIFICATIONS_WRITER_V2_MENTION`（`levels.rs:263`）。**这两个常量都没有接进 `TIMELINE_HOME_RECOMMENDATIONS` 或 `TIMELINE_HOME`。** 所以 `DUPLICATE_CONTENT`、`DUPLICATE_MENTION`、`ABUSIVE`、`UNTRUSTED_URL`、`DOWNRANK_SPAM_REPLY`、`SMYTE_SPAM_TWEET`、`RISKY_HIGH_VIZ_REPLY` **压制的是通知，不是 For You 触达**。具体后果：Grox 的 `RISKY_HIGH_VIZ_REPLY`（botmaker 规则 25026，`spamScore >= 0.97`，TTL 14 天，`botmaker-rules/scarecrow/bot/GroxTweetProcessor.bot:1`、`:8`、`:27-29`）**让被你回复的人收不到回复通知，但不会把这条回复从 For You 里删掉**。

两个必须分清的例外：`SPAM_HIGH_RECALL` **确实**会掉 For You —— 走 `OON_POST_DROPS` 里的 `spam_high_recall/drop/undesirable`（`NonAuthors`，`levels.rs:218`、`:378`），不是通知面那条 `NonFollowers` 的 `_oon` 变体；`LOW_QUALITY` 在通知面只有 **2019-04-01 之前**发的帖才 DROP（`!TweetCreatedAfter(1554076800000)`，`tweet_rules.rs:961-969`），之后的帖走渲染层公共利益插屏（§5.2）。

### 4.4 黄金样例反推（最硬的证据）

| 样例 | 结果 | 行号 |
|---|---|---|
| `abusive_high_recall_user_label`、`do_not_amplify_user_label` | **只有 `Role::NonFollower` 被丢，`Follower` 与 `Author` 都 allow** | `golden_corpus/oon_user_label.rs:129-143`、`:159-173` |
| `nsfw_high_recall` / `nsfw_high_precision` / `spam_high_recall` / `compromised` / `read_only` / `impersonation` / `nsfw_avatar` / `nsfw_banner` / `nsfw_near_perfect` 作者标签 | **Follower 也丢，只有 Author allow**（`NonAuthors`） | `golden_corpus/oon_user_label.rs:10-128`、`:144-158` |
| `malicious_url`、`do_not_amplify` 推文标签 | NonFollower + LoggedOut 丢；Follower + Author allow；**`TimelineHome` 上 NonFollower 也 allow** | `golden_corpus/oon_tweet_label.rs:17-31`、`:47-61` |
| `nsfw_high_recall` 推文标签 | **Follower 也丢** | `golden_corpus/oon_tweet_label.rs:32-46` |
| `brazil_election_legal` | **即使关注了作者，请求国是 `br` 仍然丢**（`NonAuthors` + 国家条件，不是 OON 规则） | `golden_corpus/oon_tweet_label.rs:77-132` |
| `fosnr_abuse_insults` | Author → `appealed(ABUSE, level=1)`；NonFollower / LoggedOut → drop；**Follower → soft_intervention**；关掉 `FosnrRules` 的老客户端 → `fosnr_fallback/drop`；**在 Recommendations 上 Follower 与 NonFollower 一律 drop** | `golden_corpus/oon_tweet_label.rs:133-196` |

`Role::views()`：`Follower` 额外加 `Hydrator::Follows`；`LoggedOut` 清空所有关系边（`golden_corpus/mod.rs:132-165`）。

---

## 5. 标签枚举与处置映射

### 5.1 作者级 `AuthorLabel`：完整枚举在仓库内（`author.rs:20-37`，`#[repr(u8)]`，存成 `u64` 位图 `:40-52`）

```
NsfwHighRecall=0   NsfwHighPrecision=1  NsfwNearPerfect=2   NsfwAvatarImage=3
NsfwBannerImage=4  SpamHighRecall=5     AbusiveHighRecall=6 Compromised=7
ReadOnly=8         ImpersonationHighPrecision=9  DoNotAmplify=10  NotGraduated=11
AgathaSpamTopUser=12  EngagementSpammer=13  BlinkWorst=14  DownrankSpamReply=15
```

推文级 `SafetyLabelType` 是 `pub use xai_x_thrift::tweet_safety_label::SafetyLabelType;`（`safety_labels.rs:1`）——**权威 IDL 枚举与数字 ID 不在本仓库，未公开**；仓库代码实际引用 53 个变体。

### 5.2 推文级标签 → 处置

| SafetyLabelType | 处置 | audience | 证据 |
|---|---|---|---|
| `PDNA` | DROP `NsfwHighPrecisionSafetyResult` | NonAuthors | `tweet_rules.rs:28-33` |
| `BOUNCE` | DROP `TweetIsBounced`；引用内层 → **Tombstone(Bounced)** | NonAuthors / Everyone | `tweet_rules.rs:35-47` |
| `SPAM` / `SPAM_HIGH_RECALL` | DROP `PossiblyUndesirable` | NonAuthors | `tweet_rules.rs:49-54`、`:944-949` |
| `FOR_EMERGENCY_USE_ONLY` | 召回三层 DROP；渲染层动态插屏（§3.5） | Everyone | `tweet_rules.rs:56-68` |
| `LOW_QUALITY` | 渲染层**公共利益插屏** + `NonCompliant` 限权（2019-04-01 后）；通知面对更早的帖 DROP | Everyone / NonAuthors | `tweet_rules.rs:70-87`、`:961-969`；`rule_spec.rs:744-754` |
| `MISINFO_CIVIC` / `CRISIS` / `GENERIC` / `MEDICAL`、`IPI_DEVELOPMENT_ONLY` | 公共利益插屏，限权 reason 由 label `source` 字符串决定；`IPI_DEVELOPMENT_ONLY` 用插屏 `DEVELOPMENT_ONLY_PUBLIC_INTEREST` + `NonCompliant` | Everyone | `rule_spec.rs:755-758`、`:759-762` |
| `FOSNR_HATEFUL_CONDUCT` / `VIOLENT_SPEECH` / `ABUSE` / `CIVIC_INTEGRITY` | 非作者 DROP；**作者本人 → Appealable，level=3，13 项限权** | NonAuthors / OnlyAuthor | `tweet_rules.rs:141-167`、`:108-132`、`:201-206` |
| `FOSNR_ABUSE_INSULTS` | Rec：非作者一律 DROP；Hydration：陌生人 DROP、**粉丝 soft_intervention(level=1)**、**作者 Appealable(level=1，仅禁 `EditTweet`)** | 见左 | `tweet_rules.rs:169-199`、`:133-138` |
| `FOSNR_APPEAL_SUBMITTED` | **不改变任何判定**，只把 `appeal_submitted` 置 true（§10.1） | — | `rule_spec.rs:675` |
| `NSFW_HIGH_PRECISION` | Rec / Immersive：DROP `ContainNsfwMedia`；Home：blur；Hydration：按国家 × 客户端 → tombstone / blur+age_prompt / legacy（§6.4） | NonAuthors（`*_all_users` 变体 Everyone） | `tweet_rules.rs:454-584` |
| `NSFW_HIGH_RECALL` | DROP `ContainNsfwMedia` | NonAuthors | `tweet_rules.rs:912-918` |
| `GORE_AND_VIOLENCE_HIGH_PRECISION` | Rec：DROP；Home：blur `Violence`；Hydration：`GoreBlurIgnoresSettings` 开启时**无视观众设置强制 blur** | NonAuthors | `tweet_rules.rs:586-667` |
| `NSFW_CARD_IMAGE` | Rec：DROP；Home / Hydration：blur `Sensitive` / tombstone / legacy | NonAuthors | `tweet_rules.rs:669-749` |
| `NSFW_TEXT` / `NSFW_TEXT_HIGH_PRECISION` / `NSFW_VIDEO` | 参与 `IS_NSFW_SENSITIVE_TWEET`；`NSFW_TEXT` + `NSFW_CARD_IMAGE` 触发 logged-out / underage / no-stated-age 硬 DROP | NonAuthors | `rule_spec/conditions.rs:25-31`、`:48-59`；`tweet_rules.rs:313-380` |
| `SOFT_NSFW` | DROP，**三重门且 DDG 开关默认 false**（§3.3） | NonAuthors | `tweet_rules.rs:919-928`；`client_switches.rs:15`、`:141-147` |
| `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | **DROP，仅陌生人** | NonFollowers | `tweet_rules.rs:930-935`、`:937-942` |
| `BRAZIL_ELECTION_LEGAL` | DROP，条件 `RequestCountryIs("br")` | NonAuthors | `tweet_rules.rs:951-959` |
| `DYNAMIC_PRODUCT_AD` | **LimitedEngagement(DynamicProductAd)**，8 项限权，无文案 | Everyone | `tweet_rules.rs:1151-1156` |
| `DUPLICATE_CONTENT` / `SMYTE_SPAM_TWEET` / `ABUSIVE` / `UNTRUSTED_URL` / `DUPLICATE_MENTION` / `DOWNRANK_SPAM_REPLY` / `RISKY_HIGH_VIZ_REPLY` | **只接通知面**（§4.3） | NonAuthors / NonFollowers | `tweet_rules.rs:971-1034`；`levels.rs:190-199`、`:253-259` |
| `EGREGIOUS_NSFW`、`NSFA_*`、`GROK_*`、`PTOS_REVIEWED`、`NSFW_REPORTED_HEURISTICS`、`GORE_AND_VIOLENCE_REPORTED_HEURISTICS`、`DEPRECATED_LABEL_144` | **visibility-filtering 完全不读**，只在 home-mixer 的品牌安全分级里用 | — | `home-mixer/models/brand_safety.rs:73-99` |

### 5.3 标签元数据决定 FOSNR 语义

`SafetyLabelMap{types, by_agent, sources}`（`safety_labels.rs:7-11`）：`by_agent` 在 source 是 `ToolAction`（人工 / 客服工具打标）时置位（`:51-56`）；`sources` **只对 7 个标签读 source 字符串**（`SOURCE_READ_LABELS`，`:14-22`）：`LOW_QUALITY, MISINFO_CIVIC, MISINFO_GENERIC, MISINFO_MEDICAL, MISINFO_CRISIS, IPI_DEVELOPMENT_ONLY, FOR_EMERGENCY_USE_ONLY`。`fosnr_reason()`：`proactive = !labels.is_by_agent(label)`，`appeal_submitted = labels.has_label(FOSNR_APPEAL_SUBMITTED)`（`rule_spec.rs:665-677`）→ **人工打标的 FOSNR 不算 proactive（主动执法）**。`LOW_QUALITY` 的 source 去下划线大写比对 30 个 `SafetyResultReason`（`rule_spec.rs:694-732`），匹配不上落 `ONE_OFF`（`:752`）。

标签来源三种：`BotMakerAction`（带 `rule_id`）、`ToolAction(AgentTool, actor_ldap)`、`GrokAnnotationAction`（`visibility-filtering-client/tweet_safety_label.rs:188-226`）。标签还带 `score / applicable_users / holdback_experiment / created_at_msec / expires_at_msec / applicable_countries`（同处）。**`applicable_countries` 字段在 visibility-filtering 的规则里没有被读取**，规则只用 `RequestCountryIn` / `RequestCountryIs`。

---

## 6. 成人 / 暴力内容：推荐流直接丢，渲染层才模糊

### 6.1 `PREEMPTED`：6 条 blur 在 Recommendations 上永不触发

`golden_corpus/mod.rs:673-710` 把这件事钉死（另见 `rule_spec/laws.rs:687-694` 的 `WIRED_DIFFERENTLY`）：

| 被抢占的 blur 规则 | 抢占者（Drop 17，条件更宽，不带 `!ViewerAllowsSensitiveMedia`） |
|---|---|
| `nsfw_high_precision/blur/nudity`、`nsfw_high_precision/blur/sensitive` | `nsfw_high_precision/drop/nsfw_media` |
| `gore_and_violence_high_precision/blur` | `gore_and_violence_high_precision/drop/nsfw_media` |
| `nsfw_card_image/blur/sensitive` | `nsfw_card_image/drop/nsfw_media` |
| `nsfw_admin/blur/sensitive` | `nsfw_admin_author/drop/nsfw_media` + `nsfw_admin_tweet_flag/drop/nsfw_media` |
| `nsfw_user/blur/sensitive_user` | `nsfw_user_author/drop/nsfw_media` + `nsfw_user_tweet_flag/drop/nsfw_media` |

**结论：For You 里的成人 / 暴力内容不是被模糊，而是直接被丢；模糊只发生在 Hydration（渲染）层。** 对照样例 `golden_corpus/local_regulations.rs:27-54`：同一条 `NSFW_HIGH_PRECISION` 媒体帖在 Recommendations → tombstone/drop，在 `TimelineHome` → 普通 `Sensitive` blur。

### 6.2 四张国家名单（`params.rs:43-48`，代码默认值 `:77-91`）

位图 `CountryCodes([u64; 11])`，只接受 2 字母小写码（`params.rs:99-132`），**每 30 秒从 feature switch 刷新**（`params.rs:370-379`）——下面是**代码默认值**，线上真实名单由未公开的 YAML 决定。

| CountryList | feature switch key | 默认成员 |
|---|---|---|
| `AgeVerification` = `Tombstone` | `country_specific_nsfw_content_gating_age_verification_countries` / `..._tombstone_countries` | **30 国**：`at au be bg br cy cz de dk ee es fi fr gb gr hr hu ie it lt lu lv mt nl pl pt ro se si sk`（EU/EEA + 英国 + 巴西 + 澳大利亚） |
| `NsfwGating` | `country_specific_nsfw_content_gating_countries` | **16 国**：`ar au br ca de es fr gb id it kr mx nl ph pt th` |
| `LocalRegulations` | `country_specific_nsfw_content_gating_local_regulations_countries` | **`["in"]`（仅印度）** |

`LocalRegulations` 的唯一用途是 `nsfw_high_precision/tombstone/local_regulations`（`tweet_rules.rs:485-493`）。样例 `golden_corpus/local_regulations.rs:27-54`：请求国 `in` → **即使开了敏感内容开关也 tombstone**；作者账号国 `in` 但请求国别处 → 普通 blur；web + `us` → 普通 blur。

### 6.3 客户端能力与 6 个开关

`VerifyBlurSupport::{Unsupported, IosNeedsUpdate, AndroidNeedsUpdate, Supported}`（`viewer.rs:202-208`），**代码默认 `Some(Unsupported)`**（`viewer.rs:298-301`）。四个 feature switch key（`client_switches.rs:37-44`）：`Unsupported → age_verification_uk_tombstone_rule_enabled`、`IosNeedsUpdate → age_verification_ios_tombstone_rule_enabled`、`AndroidNeedsUpdate → age_verification_android_tombstone_rule_enabled`、`Supported → age_verification_blurred_media_interstitial_rule_enabled`。无 TwitterContext 时直接用 `ClientCapability::DEFAULT`；否则逐 key 取 bool，缺省回落默认（`client_switches.rs:118-139`）。

`ClientSwitch` 6 个的**代码默认值**（`viewer.rs:212-230`，key 映射 `client_switches.rs:18-35`）：

| switch | 默认 | feature switch key |
|---|---|---|
| `StaleTweetLimits` | **true** | `stale_tweet_limited_actions_rules_enabled` |
| `FosnrRules` | **true** | `freedom_of_speech_not_reach_rules_enabled` |
| `ModernBlur` | **false** | `media_visibility_treatments_blurred_media_interstitial_enabled` |
| `CommunityViewerRemovedLimits` | **false** | `community_tweet_viewer_removed_limited_actions_rules_enabled` |
| `GoreBlurIgnoresSettings` | **false** | `media_visibility_treatments_blurred_media_interstitial_ignore_settings_enabled` |
| `FosnrFallbackDrops` | **false** | `freedom_of_speech_not_reach_fallback_drop_rules_enabled` |

**注意区分**：`fixtures.rs:29-134` 里那 8 个客户端类（`web` app_id 3033300 = Supported+MODERN、`ios_current` 129032、`ios_outdated`、`android_current` 258901、`android_outdated`、`android_without_fosnr`、`mac_app` 557701 = Unsupported+LEGACY、`third_party_client` app_id 0）是**测试夹具，不是生产配置**。真实的「哪个客户端拿到哪个能力」由未公开的 `age_verification.yml` / `media_visibility_treatments.yml` 决定（`params.rs:26-34`）。`MODERN = DEFAULT_ON + ModernBlur + GoreBlurIgnoresSettings`（`fixtures.rs:40`）。

### 6.4 `NSFW_HIGH_PRECISION` 渲染层决策树

**时间切点 `NSFW_HIGH_PRECISION_CHANGED_AT = 1705536000000`（2024-01-18 UTC）**（`tweet_rules.rs:454`）。判定用 snowflake：`tweet_timestamp_ms(id) = (id >> 22) + 1288834974657`（`mod.rs:35-39`），`created_after()` 是**严格大于**（`context.rs:188-190`）。

| 条件（自上而下，命中即止） | 处置 | 行号 |
|---|---|---|
| 请求国 ∈ `LocalRegulations`(in) | **Tombstone(LocalRegulations)**，无视敏感开关 | `tweet_rules.rs:485-493` |
| `Unsupported` + 请求国 ∈ Tombstone(30 国) + 未年龄验证 | **Tombstone(SensitiveViewerAgeVerification)** | `:495-504` |
| `IosNeedsUpdate` / `AndroidNeedsUpdate` + 同上 | Tombstone(UpdateAppIos) / Tombstone(UpdateAppAndroid) | `:506-515`、`:517-526` |
| `Supported` + 请求国 ∈ AgeVerification(30 国) + 未验证 + **cutoff 前 / 后** | blur `Sensitive` / blur `Nudity`，均带 **AGE_VERIFICATION_PROMPT** | `:528-538`、`:552-562` |
| `Everyone` + `!ViewerAllowsSensitiveMedia` + `ModernBlur` + cutoff 前 / 后 | blur `Sensitive` / `Nudity`（**作者也遮挡**） | `:540-550`、`:564-574` |
| `NonAuthors` + `!ViewerAllowsSensitiveMedia`（Home 层）+ cutoff 后 / 前 | blur `Nudity` / `Sensitive` | `:456-465`、`:467-476` |
| `Everyone` + `!ModernBlur` | **legacy_nsfw_interstitial**（老式整推插屏） | `:576-584` |
| Rec / Immersive 层 | **DROP `ContainNsfwMedia`** | `:478-483` |

- **逃掉 tombstone 的四条路**：`age_verified_18` 标签 / 是作者本人 / `has_idv_premium` / 请求国 `us` → 都退化成普通 blur（`golden_corpus/age_verification.rs:163-233`）。**`ViewerProfile` + `ViewerLabels` 查询失败也照样门禁**（fail-closed，`:358-377`）。
- 推文级 nsfw flag（`NSFW_ACCOUNT`）走同一套，但用 `AgeVerification` 名单而非 `Tombstone` 名单（`tweet_rules.rs:813-859`）——两张名单默认成员相同，只有开关漂移时才有差别。`NSFW_ADMIN` 优先于 `NSFW_USER`（`golden_corpus/interstitial.rs:33-54`）；admin + gore 同时命中时 admin 赢（`golden_corpus/age_verification.rs:587-614`）。
- 遮挡下发形态：`BlurredImageInterstitial{reason, opacity: 0.8, interstitial_action, available_verification_options}`（`thrift.rs:454-467`）；带 age prompt 时给验证方式 `[SELFIE, PERSONA]`（`thrift.rs:449-452`）。

### 6.5 `GORE_AND_VIOLENCE_HIGH_PRECISION`

| 条件 | 处置 | 行号 |
|---|---|---|
| Rec / Immersive | DROP `ContainNsfwMedia` | `tweet_rules.rs:596-603` |
| `NonAuthors` + `!ViewerAllowsSensitiveMedia`（Home） | blur `Violence` | `:586-594` |
| **`ClientHas(GoreBlurIgnoresSettings)`（不看观众设置）** | **强制 blur `Violence`** | `:659-667` |
| `Everyone` + `!ViewerAllowsSensitiveMedia` + `ModernBlur` | blur `Violence` | `:627-636` |
| `Supported` + AgeVerification 国 + 未验证 | blur `Violence` + age prompt | `:648-657` |
| `IosNeedsUpdate` / `AndroidNeedsUpdate` + Tombstone 国 + 未验证 | Tombstone(UpdateApp*) | `:605-625` |
| `!ModernBlur` | legacy interstitial | `:638-646` |

**gore 没有 `Unsupported → age_verification tombstone` 分支**（只有 ios/android 需更新两条），所以 web / mac / 第三方客户端在 gore 上落到 `legacy_interstitial`（`golden_corpus/age_verification.rs:139-153` 的 `gore` 分派表）。样例 `:615-669`：**开了敏感内容开关的 fr / us 观众，只要客户端有 `GoreBlurIgnoresSettings`，仍然被 blur**；关掉该开关则回到 `gore_and_violence_high_precision/blur/age_prompt`；作者本人 allow。

### 6.6 传播到引用 / 反应推

`REACTED_TO_RULES` 只在 `TimelineHomeHydration`（`levels.rs:399`、`:479-483`），**广告层没有**：`original_tweet_adult_media_propagation/blur/sensitive`（Everyone，`ReactedToPostHasLabel(NSFW_HIGH_PRECISION)`，`tweet_rules.rs:861-866`）、`original_tweet_gore_media_propagation/blur/violence`（`:868-875`）、`protected_original_author/drop`（`ReactedToAuthorIsProtected`，`:877-882`）。

---

## 7. 年龄门禁

### 7.1 阈值与观众年龄三态

**`ADULT_AGE_YEARS: i32 = 18`**（`viewer.rs:155`）；`ViewerAge::{Known(i32), NotStated, Unknown}`，`#[default] Unknown`（`viewer.rs:158-163`）。`is_underage()` = `Known(age) if age < 18`（`:192-194`）；`has_no_stated_age()` = `== NotStated`（`:196-198`）→ **`Unknown`（年龄查不到）不触发 no-stated-age 门禁，`NotStated`（明确没填）才触发，两者绝不能混**。`ViewerAgeVerified` = **`age_verified_18 || profile.has_idv_premium`**（`rule_spec/features/compound.rs:69-73`）→ **买了 IDV Premium 也算已验证**；`age_verified_18` 来自 `has_age_verified_18_label`（`rule_spec/features/viewer.rs:199-210`）。`ViewerAllowsSensitiveMedia` = `profile.allows_sensitive_media`（`rule_spec/features/viewer.rs:59-61`）。

### 7.2 9 条硬 DROP（`AGE_GATING_DROPS`，`levels.rs:157-167`，全部 `NonAuthors`，证据 `tweet_rules.rs:294-380`）

| 规则 | 条件 | DropReason |
|---|---|---|
| `sensitive_viewer_logged_out/drop/media_label` | `ViewerLoggedOut && TweetHasMedia && HAS_NSFW_MEDIA_LABEL` | `NsfwViewerLoggedOut` |
| `sensitive_viewer_logged_out/drop/nsfw_flag` | `ViewerLoggedOut && TweetHasMedia && !TweetIsRetweet && IS_NSFW_FLAGGED` | 同上 |
| `sensitive_viewer_logged_out/drop/text_or_card_label` | `ViewerLoggedOut && HAS_NSFW_TEXT_OR_CARD_LABEL` | 同上 |
| `sensitive_viewer_underage/drop/*` ×3 | 把 `ViewerLoggedOut` 换成 `ViewerUnderage` | `NsfwViewerIsUnderage` |
| `sensitive_viewer_no_stated_age/drop/*` ×3 | `ViewerNoStatedAge && ViewerAccountOrRequestCountryIn(NsfwGating) && …` | `NsfwViewerHasNoStatedAge` |

三个命名条件（`rule_spec/conditions.rs`）：`HAS_NSFW_MEDIA_LABEL` = `NSFW_HIGH_PRECISION | NSFW_HIGH_RECALL | GORE_AND_VIOLENCE_HIGH_PRECISION`（`:6-13`）；`IS_NSFW_FLAGGED` = `AuthorIsNsfwUser | AuthorIsNsfwAdmin | TweetNsfwUserFlag | TweetNsfwAdminFlag`（`:15-23`）；`HAS_NSFW_TEXT_OR_CARD_LABEL` = `NSFW_TEXT | NSFW_CARD_IMAGE`（`:25-31`）。

### 7.3 豁免边界（开关能绕过什么、不能绕过什么）

| 事实 | 证据 |
|---|---|
| **转推不受 nsfw_flag 年龄门禁约束**（`!TweetIsRetweet`）；nsfw user flag 的媒体被转推 → 变成 `SensitiveUser` blur | `tweet_rules.rs:307`、`:333`、`:365`；`golden_corpus/age_gating.rs:220-239` |
| **未成年作者看自己的帖 allow**（`NonAuthors`）；**敏感内容开关不能绕过未成年门禁**：17 岁 + opted-in → 仍然 `IsUnderage` drop | `golden_corpus/age_gating.rs:32-137` |
| **`no_stated_age` 只在 16 个 `NsfwGating` 国家生效**：gb / de 请求被丢、kr 账号 + us 请求被丢；us 请求、us 账号 + de 请求、无国家、`Unknown` 年龄在 gb → 在 `TimelineHome` 上 allow | 同上 |
| **`LoggedOut` 无条件丢，不看国家** | `tweet_rules.rs:294-318` |
| 开关能豁免的只有 blur（`ViewerAllowsSensitiveMedia`）；**豁免不了** underage / logged-out / no-stated-age 硬 DROP、gore 的 `IgnoringSettings`、印度的 `LocalRegulations` | `tweet_rules.rs:462`、`:473`、`:591`、`:674`、`:754`、`:785`、`:659-667`、`:485-493` |

---

## 8. 法律下架：`xx` / `xy` 与三种国家粒度

### 8.1 两个全球码与两个提取器

`tweet.rs:101-107`：`WORLDWIDE_COUNTRY_CODE = "xx"`、`WORLDWIDE_COPYRIGHT_COUNTRY_CODE = "xy"`，`is_worldwide_code(c)` 大小写不敏感。匹配逻辑 `takedown_in()` = `is_worldwide_code(c) || request_country.eq_ignore_ascii_case(c)`（`tweet.rs:82-90`）。

| TakedownReason | `legal_takedown_country()`（`tweet.rs:109-124`） | `local_laws_takedown_country()`（`tweet.rs:126-139`） |
|---|---|---|
| `LegalRequest{"xy"}` | **`None`** —— **版权类全球请求不在 legal_takedown 里执行** | `None` |
| `LegalRequest{cc}` / `UnspecifiedReason{cc}` | `Some(cc)`；`cc=="xx"` → 全球丢，否则匹配请求国 | `None` |
| `Dmca` | `Some("xy")` → `is_worldwide_code("xy")` → **全球丢** | `None` |
| `BystanderReport{cc}`，cc 非 xx/xy | `None` | `Some(cc)` → 只在该国丢 |
| `BystanderReport{"xx"\|"xy"}` | `None` | **`None`（全球 bystander report 不被 local laws 执行）** |
| `HatefulImagery` / `SensitiveImagery` / `Unknown` | `None` | `None` |

**两条规则的 audience 都是 `NonAuthors`**（`tweet_rules.rs:246`、`:253`）→ **作者本人永远看得到自己被下架的推。**

### 8.2 黄金样例（`golden_corpus/takedown.rs`）

| 场景 | 结果 | 行号 |
|---|---|---|
| `LegalRequest{"us"}`，请求国 us / fr | DROP / **allow** | `:11-33` |
| `LegalRequest{"xx"}` / `{"xy"}` | 全球 DROP / **allow**（版权不走 geo 执行） | `:34-50`、`:51-58` |
| `UnspecifiedReason{"xx"}` / `{"xy"}` | **都 DROP** | `:59-86` |
| `BystanderReport{"xx"}`；`HatefulImagery` + `Unknown` | **allow** | `:87-94`、`:140-147` |
| `TakedownReason::Dmca` | NonFollower DROP，Author allow | `:95-109` |
| `BystanderReport{"de"}`，请求国 de | DROP via `local_laws_takedown`；**账号国 de 但请求国别处 → allow** | `:110-139` |
| 大写 `"XX"` / `"XY"` | DROP（大小写不敏感）/ allow | `:148-164`、`:165-192` |

### 8.3 三种国家粒度，务必区分

| 粒度 | 语义 | 用在哪 | 证据 |
|---|---|---|---|
| `RequestCountryIs("br")` / `RequestCountryIn(list)` | **只看请求国**（IP / 请求上下文），不看账号国 | `brazil_election_legal`、所有 tombstone / age_verification 条件 | `tweet_rules.rs:956`；`rule_spec/conditions.rs:90`、`:98` |
| `ViewerAccountOrRequestCountryIn(list)` | **账号国优先，账号国缺失才回落请求国** | `sensitive_viewer_no_stated_age` 三条 | `rule_spec.rs:799-808`；`tweet_rules.rs:351`、`:363`、`:376` |
| 媒体 geo allow / deny | `country = request_country.unwrap_or("xx")`；`(!allow.is_empty() && !allow.contains(country)) \|\| deny.contains(country)`，大小写不敏感 | `geo_restricted_media/drop` | `tweet.rs:92-98` |

**没有请求国时媒体 geo 按 `"xx"` 处理，allow-list 非空则几乎必丢。** 媒体 geo 名单**不做大区码展开**——`models/region.rs` 的 `AFR / AUS / CAS / EAS / EUR / NAM / SAM / SAS / SEA / WES` 展开函数 `allows_country()`（`region.rs:61-71`）只被 `ViewerIsInAllowedCountry`（限回复的国家白名单）调用（`rule_spec/features/compound.rs:87-93`），与媒体 geo 无关。

### 8.4 上游 Scala：账号级下架合并进推文级

- `takedowns/tweet-entity-service/TakedownReasonsTransform.scala:52-69`：`tweetFields.hasTakedown == true` 时 `combinedTakedownReasons = tweetTakedownReasons ++ userTakedownReasons`，并保留 `tweetypieOnlyTakedownReasons`。用户级下架来自 Gizmoduck `QueryFields.Takedowns`（`:19-34`）。→ **账号被下架会让该账号所有推都带上 takedown reason。** 字段名 `takedownReasons` / `TweetFieldKeyType.TakedownReasons`（`takedowns/tweet-entity-service/TakedownReasonsColumn.scala:18-25`）。
- `takedowns/gizmoduck/RedactUnenforcedTakedownsFilter.scala:64-81`：读侧过滤器（受 `enableReadGate` 控制，`:43`）把**未执行的**下架从用户对象剔除：`UnspecifiedReason("xy")`、`LegalRequest("xy")`、`BystanderReport("xx"|"xy")`、`Dmca` 全部 redact（`:68-78`），计数 `redacted_unenforced_takedowns`（`:24`）。挂在 `ReadFilters.scala:37` 过滤链末尾。

---

## 9. 展示但限权：`LimitedEngagement`

### 9.1 三层「限流」概念别混淆

**`LimitedEngagement`（severity 6）**＝帖照常展示、某些按钮被禁；**FOSNR（Freedom of Speech, Not Reach）**＝陌生人 DROP、粉丝 soft intervention、作者 appealable + 限权；**`NonFollowers` audience DROP**＝事实上的「不推荐但粉丝可见」。**本子系统没有「降权」档位。** home-mixer 的 `BrandSafetyVerdict{Unspecified=0, Safe=1, LowRisk=2, MediumRisk=3, HighRisk=4}`（`home-mixer/models/brand_safety.rs:7-14`）是**广告邻接**分级（`home-mixer/ads/neighbours.rs`），不是自然流量降权。

### 9.2 14 个 reason × 实际禁用动作

`LimitedEngagementReason` 14 值（`verdict.rs:218-233`），对外字符串 `:236-253`。可禁动作 `LimitedActionType` 26 种（`verdict.rs:51-78`，wire 映射 `thrift.rs:416-447`）：`Reply, Retweet, QuoteTweet, Like, React, SendViaDm, AddToBookmarks, AddToMoment, PinToProfile, ViewTweetActivity, ShareTweetVia, Follow, ListsAddRemove, MuteConversation, Embed, ViewHiddenReplies, HideCommunityTweet, CopyLink, VoteOnPoll, RemoveFromCommunity, ShowRetweetActionMenu, ReplyDownVote, Autoplay, EditTweet, Highlight, ViewPostEngagements`。

策略文件 `../../visibility-limited-actions/main/limited_actions_policy.yml`（`params.rs:36-37`）**不在仓库**。生效表由 pinned 测试 `each_reason_resolves_its_policy_from_the_scala_file` 钉死（`limited_actions_policy.rs:167-363`）：

| Reason | copy namespace | 禁用动作 | 证据 |
|---|---|---|---|
| `NonCompliant` | `NonCompliant` | **11 项** | `limited_actions_policy.rs:197-213` |
| `ConversationControl` | `LimitedReplies` | `[Reply]` | `:214` |
| `BlockedViewer` | `BlockedViewer` | **19 项** | `:215-239` |
| `RootAuthorBlockedViewer` | `BlockedViewer` | `[Reply]` | `:240-244` |
| `ReadonlyViewer` | `ReadonlyViewer` | **14 项** | `:245-264` |
| `StaleTweet` | **无文案** | **15 项** | `:265-285` |
| `CommunityTweetHidden` | `CommunityHidden` | `community_unavailable` 去掉 `RemoveFromCommunity` = **18 项** | `:286-290`、`:170-190` |
| `CommunityTweetMemberRemoved` / `NotFound` / `Suspended`；`CommunityTweetCommunityDeleted`；`CommunityTweetViewerRemoved` | `Default`；`Default`；`ViewerIsRemovedFromCommunity` | 依次：`community_unavailable` **19 项**；`[HideCommunityTweet, RemoveFromCommunity]`；`[Reply, PinToProfile]` | `:291-310`、`:170-190`；`:301-305`；`:311-315` |
| `DynamicProductAd` | **无文案** | **8 项** | `:316-329` |
| `LocalTweet` | `LocalPost` | `[Retweet, Reply]` | `:330` |

### 9.3 FOSNR 两档限权

- **level 3**（`FOSNR_ABUSE / CIVIC_INTEGRITY / HATEFUL_CONDUCT / VIOLENT_SPEECH`）→ `AUTHOR_LEVEL_3_LIMITED_ACTIONS` **13 项**：`Like, Reply, Retweet, QuoteTweet, ShareTweetVia, AddToBookmarks, PinToProfile, CopyLink, SendViaDm, EditTweet, Highlight, Embed, ListsAddRemove`（`tweet_rules.rs:89-106`）。**level 1**（`FOSNR_ABUSE_INSULTS`）→ **仅 `[EditTweet]`**（`tweet_rules.rs:133-138`）。
- wire 上 `limited_engagements.reason` = `(reason.level != 1).then(|| "freedom_of_speech_not_reach")`（`thrift.rs:250`）→ **level 1 不打 FOSNR 标记**。soft intervention 下发形态：`engagement_nudge=false, suppress_autoplay=true, display_type=FOSNR, warning=None, details_url=None`（`thrift.rs:254-265`）→ **粉丝看到的是「抑制自动播放 + FOSNR 提示」，不是硬遮挡**。`Appealable` / `SoftIntervention` 都带 `Avoid{brand_safety_risk_level: NORMAL}`（`thrift.rs:212-214`）。

### 9.4 用户文案

文案 bundle `/config/stringcenter/visibility-ltd-actions.json`（`limited_actions_copy.rs:10`）**未公开**。机制：key = `{namespace}_{Action}_Headline` / `_Subtext`；`{namespace}_GenericSubtext` **只有 `BlockedViewer` 和 `ReadonlyViewer` 共享**（`:14`、`:99-140`）。`PromptKind::{Basic, SeeConversation, LearnMore{link_text, url}}`（`:35-42`）由开关 `limited_actions_policy_copy_namespace` / `_prompt_type` / `_prompt_learn_more_url` 决定：`"NoCopy"` → 无文案，`"cta"` → SeeConversation，有 url → LearnMore（`:157-177`）。占位符 `learnmore`（`:16`），wire 侧 `LEARN_MORE_PLACEHOLDER`（`thrift.rs:286`、`:303`、`:405`）。

**只有测试 BUNDLE 里的 EN/JA 片段是可见的真实字符串**（`limited_actions_copy.rs:228-247`）：`"Who can reply?"` / `"Only some accounts can reply."` / ja「一部のアカウントのみが返信できます。」；`"Why can't you like this?"`；`"This author has blocked you, so you can't perform this action"`；`"You cannot reply"` / `"You cannot reply this post"`。公共利益插屏只有 resname 公开（`thrift.rs:314-356`）：`public_interest.*`（`.episodic / .self_harm / .hateful_conduct / .gratuitous_gore / .glorifying_violence / .mob_harassment / .moment_of_death / .private_information / .right_to_privacy / .threat_to_expose / .violent_sexual_conduct / .violent_threat / .voting_misinformation / .hacked_materials / .scams / .platform_manipulation / .one_off`）、`misinfo.civic / .crisis / .generic / .medical`、`fosnr.abusive_behavior / .civic_integrity / .hateful_conduct / .violent_speech / .synthetic_and_manipulated_media`。链接 `MISINFO_CIVIC→links::ELECTION_INTEGRITY`、`MISINFO_CRISIS→links::CRISIS_MISINFORMATION`、`MISINFO_GENERIC→links::TWITTER_RULES`、其余 `links::PUBLIC_INTEREST`（`:349-354`）。**译文未公开**（走 `graphql_results::translate`）。

---

## 10. 豁免清单，以及最重要的否定结论

### 10.1 提交申诉**不改变任何可见性判定**

`FOSNR_APPEAL_SUBMITTED` **只影响 `FosnrReason.appeal_submitted` 布尔位**（`rule_spec.rs:675`），进而只影响下发的 `AppealableReason`（`thrift.rs:216-223`）。**没有任何规则的 `when` 读取 `FOSNR_APPEAL_SUBMITTED`**：条件侧只有 `HAS_FOSNR_LABEL`，而它只列 5 个违规标签，不含 appeal 标签（`rule_spec/conditions.rs:75-84`）。`appeal()` 只是「找到第一个命中的 violation → 构造 Notice」，没有任何豁免分支（`rule_spec.rs:655-663`）。**黄金样例钉死**：`golden_corpus/oon_tweet_label.rs:197-226`（`fosnr_abuse_insults_by_agent_under_appeal`）—— 加上 `with_agent_label` + `FOSNR_APPEAL_SUBMITTED` 后 `proactive=false, appeal_submitted=true`，**但判定完全不变**：陌生人仍 drop、粉丝仍 soft_intervention、作者仍 appealable。

**结论：申诉状态在 visibility-filtering 里纯粹是展示层信息（让客户端显示「已申诉」）。真正的解除必须由上游撤销标签来实现。仓库内不存在「申诉成功 → 规则跳过」的旁路。**

### 10.2 真实存在的豁免

| 豁免 | 条件 | 证据 |
|---|---|---|
| 作者本人豁免 | 所有 `NonAuthors` / `NonFollowers` 规则 | `rule_spec/engine.rs:67-68` |
| 粉丝豁免 | 所有 `NonFollowers` 规则（§4.2）；`fosnr_abuse_insults` 的粉丝不是全豁免而是降级成 soft_intervention | `tweet_rules.rs:186-199` |
| 社区 moderator / 作者豁免 | community 相关 drop 对版主与作者不生效 | `tweet_rules.rs:1181-1232`（测试）；`mod.rs:204` |
| 会话根作者 / 被邀请者豁免限回复 | `VIEWER_IS_NEITHER_ROOT_AUTHOR_NOR_INVITED` | `rule_spec/conditions.rs:101-108`；`tweet_rules.rs:1050-1138` |
| Super Follows 豁免独家内容；Trusted Friends 名单成员 / owner 豁免 | `ViewerSuperFollowsAuthor`；`ViewerIsTrustedFriendsListMemberOrOwner` | `rule_spec/features/compound.rs:74-78`；`tweet_rules.rs:409`、`:421`、`:444-452` |
| 转推豁免 nsfw flag 年龄门禁 / 限回复 / nullcast | `!TweetIsRetweet` | `tweet_rules.rs:307`、`:333`、`:365`、`:1120`、`:1133`、`:218` |
| 已年龄验证 / IDV Premium 豁免 tombstone + age prompt | `ViewerAgeVerified` | `rule_spec/features/compound.rs:69-73`；`golden_corpus/age_verification.rs:163-233` |
| 账号国 ≠ 请求国 | tombstone 只看请求国 | `rule_spec/conditions.rs:90`、`:98`；`golden_corpus/takedown.rs:110-139` |
| 老客户端降级 | `!ClientHas(FosnrRules)` → FOSNR 规则整体不生效；若开了 `FosnrFallbackDrops` 则改为直接 DROP；`!ModernBlur` 走 legacy 插屏而非 blur | `tweet_rules.rs:181`、`:192`、`:204`、`:211`、`:576-584`、`:638-646`、`:741-749`、`:849-859` |
| 登出观众跳过 viewer 相关 hydrator | `policy.hydrators.without_viewer()` | `engine.rs:750-756` |
| fail-open 默认值 | `Truth::Unknown{default, failed}`（`rule_spec.rs:584-652`）；`Defaults{withholding, media, engagement}`（`defaults.rs:57-99`）；`must_have()` 失败 → `Partial` → RPC `Failed` | `engine.rs:250-254`、`:189-221`；`rpc.rs:86` |
| **实验跳过：生产不存在** | `Effect::SkippedByExperiment`（`engine.rs:146-173`）存在，但 `Experiment` 只有 `#[cfg(test)] TestLaunch / TestHoldback`（`experiment.rs:6-11`），注释明写 "no experiment is wired yet"（`:16-19`） | 同左 |

---

## 11. 明确「未公开」清单

| 缺失物 | 引用位置 | 影响 |
|---|---|---|
| `visibility-filtering/docs/policy-catalog.md`、`GLOSSARY.md`（Slot 语义） | `catalog.rs:172`、`:74-85` | 官方规则目录缺失；本文顺序表由 `action_kind.rs` + `engine.rs` 重建 |
| `SafetyLabelType` 权威 IDL 枚举 + 数字 ID | `safety_labels.rs:1`（外部 crate `xai_x_thrift`） | 只能列出仓库引用的 53 个变体 |
| `FilteredReason` / `InterstitialReason` / `AppealablePolicy` / `SafetyResultReason` / `TakedownReason` / `ConversationControlArm` 完整枚举 | 均来自外部 crate | 同上 |
| 7 个 feature-switch YAML（`age_verification.yml` 等）+ `limited_actions_policy.yml` | `params.rs:26-37` | 生效值只能从 pinned 测试反推（§9.2）；国家名单与客户端能力矩阵同理 |
| `tests/fixtures/scala_client_switches.yml`、`tests/fixtures/limited_actions_policy.yml` | `client_switches.rs:105-108` | **`visibility-filtering/tests/` 目录不存在**，已确认 |
| StringCenter bundle `/config/stringcenter/visibility-ltd-actions.json` + 插屏 resname 译文 | `limited_actions_copy.rs:10`；`thrift.rs:314-356` 走 `translate()` | 真实文案只有测试 BUNDLE 的 EN/JA 片段；插屏只有 key |
| 生产实验配置 | `experiment.rs:6-11` | 生产无实验接线 |
| Search / Profile / Explore 面的可见性规则 | `SafetyLevel` 只有 9 值（`safety_level.rs:23-33`） | 「不推荐但可搜索」「仅主页可见」在本子系统无对应档位 |
| 自然流量降权权重公式 | 不在 visibility-filtering | 见 `02-scoring-ranking` |

---

## 12. 诊断速查

| 现象 | 先查什么 |
|---|---|
| 「粉丝看得到，陌生人看不到」 | `NonFollowers` 清单（§4.2）：`DO_NOT_AMPLIFY` / `MALICIOUS_URL` 推文标签，`AbusiveHighRecall` / `DoNotAmplify` 作者标签，`protected_author` |
| 「关注流有，For You 没有」 | §3.4 的 26 条差集；成人 / 暴力内容看 §6.1 |
| 「接口 allow，App 显示警告」 | §1.2 vs §1.3：`filter_tweets` 把 FOSNR / 插屏 / 限权全压成 ALLOW |
| 「回复没通知到对方」 | §4.3：`RISKY_HIGH_VIZ_REPLY` / `DOWNRANK_SPAM_REPLY` / UQF 系列只掐通知 |
| 「帖子变成墓碑」/「图片被模糊，开关也没用」 | §6.4：请求国 ∈ 30 国 + 客户端 `Unsupported`/需更新 + 未年龄验证；§6.5 gore + `GoreBlurIgnoresSettings`；§6.2 印度 `LocalRegulations` |
| 「申诉了还是没恢复」/「我自己看得到，别人看不到」 | §10.1：申诉只改展示位，必须上游撤标签；几乎所有 Drop 都是 `NonAuthors`，作者永远豁免 |