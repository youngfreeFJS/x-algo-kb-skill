# 05 · 风控打标与处置：标签从哪来、关多久

> 证据基准：commit `a284320b66a9dce35e6f5d6b052ee308eeb12326`（2026-11-17T03:20:50Z），路径均相对仓库根。
> 覆盖模块：`botmaker/`、`botmaker-rules/`、`scarecrow/`、`abuse-enforcement-service/`、`abuse-ledger-service/`、`safety-label-user-agg/`、`safety-label-source/`。
> 全文严格区分三种状态：**已验证生产默认值** / **代码在但默认关** / **未公开**。

---

## 1. 先划清可见性边界

公开规则总量是**精确可数的**：`botmaker-rules/scarecrow/bot/` 下 **20 个 `.bot`**，`botmaker-rules/scarecrow/derived-feature/` 下 **53 个 `.df`**，全仓库再无其他 `.bot`/`.df` 文件。

官方明确承认有隐藏规则：

- `README.md:333`：「The rules `scarecrow` loads. To reduce the risk of gaming to circumvent these systems, **some rules aren't currently in this repository**.」
- `README.md:444-447`：未公开清单包含「Grox prompts（j2 文件）」与「Some botmaker rules」。

**所以「我找不到 X 的规则」只能推出「X 的规则未公开」，永远推不出「X 不存在」。** 本篇所有"缺失"都是这个含义，不是"平台不管这件事"。

### 1.1 按用户关心的主题对照

| 主题 | 可见性 | 说明 |
|---|---|---|
| spam（链接 / 模型分） | 充分 | 规则 3226、20789、20998、21278、25026 |
| 重复内容 | 半可见 | 处置侧可见（BBQ 两条）；**聚类相似度阈值在 BigQuery 侧，不在仓库**；`DUPLICATE_CONTENT` 生产规则缺失 |
| bot / 自动化 | 间接 | `bb1_*_spam_bot_*` 系列在 abuse-enforcement 侧可见（第 7 节），botmaker 侧无 |
| **协同操纵 / coordinated manipulation** | **缺失** | 仅 `anchor_campaign_*` 标签名可见（`enforcement_user.yaml:37,40,44`），判定逻辑完全不可见 |
| **刷互动 / engagement farming** | **缺失** | `ENGAGEMENT_SPAMMER` 只有消费端（`author_rules.rs:260`） |
| **发帖速率限制** | **缺失** | 无任何用户发帖频率规则。仓库里的 `RateLimited` 是**保护平台自身**的闸门，不是限制用户 |
| **新号限制 `NOT_GRADUATED`** | **缺失** | 只有消费端（`author_rules.rs:246`）；home-mixer 侧另有两道新号过滤，但**默认关**（第 12.3 节） |
| 外链 | 充分 | 6 条 URL 规则 |
| @ 滥用 | 一条 | 5239，且必须叠加低质链接 |
| **话题标签滥用 / hashtag abuse** | **完全缺失** | 全仓库无 hashtag 相关处置规则 |

### 1.2 只有消费端、没有生产端的 14 个标签

在 `botmaker-rules/` 全目录反查，以下标签**产出规则命中数为 0**，但在 `visibility-filtering/` 里被明确消费——**线上一定存在，只是规则未公开**：

`DUPLICATE_CONTENT`、`DUPLICATE_MENTION`、`SMYTE_SPAM_TWEET`、`DOWNRANK_SPAM_REPLY`、`ABUSIVE`、`UNTRUSTED_URL`、`ENGAGEMENT_SPAMMER`、`NOT_GRADUATED`、`RTBot`、`COMPROMISED`、`READ_ONLY`、`IMPERSONATION_HIGH_PRECISION`、`ABUSIVE_HIGH_RECALL`、`BLINK_WORST`。

消费端证据：`visibility-filtering/rules/tweet_rules.rs:971-976`（`DUPLICATE_CONTENT`）、`:985-993`（`DUPLICATE_MENTION`，需 UQF）、`:995-1000`（`ABUSIVE`）、`:1002-1010`（`UNTRUSTED_URL`）、`:1012-1020`（`DOWNRANK_SPAM_REPLY`）、`:978-983`（`SMYTE_SPAM_TWEET`）；`author_rules.rs:246-251`（`NOT_GRADUATED`）、`:218-223`（`READ_ONLY`）、`:260-265`（`ENGAGEMENT_SPAMMER`）、`:267-276`（`BLINK_WORST`）。

另一个反直觉点：**`COPYPASTA_SPAM` 与 `SEARCH_BLACKLIST` 由 botmaker 产出，但整个 `visibility-filtering/` 里没有任何消费者**——它们作用于搜索侧，不影响 For You 推流。

### 1.3 绝不能当生产值传播的数字

| 数字 | 出处 | 性质 |
|---|---|---|
| `12.34`（粉丝数 / cred 分） | `enforcement_user.yaml:20,26`；`enforcement_post.yaml:24,30` | **官方 mock**。原文注释：「Prod uses a different follower count threshold; **this is a mock value to reduce gaming**.」 |
| `12345.67`（`FOLLOWER_CEILING`） | `service-lib/src/safety_checks.rs:158-162` | 同上，mock |

**`abuse-enforcement-service` 真实的信誉/粉丝豁免阈值未公开。** 唯一公开的真信誉门槛是 botmaker 侧的 `HighPageRankThreshold.df:2` = **54**，以及 Grox 侧的 `grox/flows/reply_spam/constants.py:9` `RISKY_HIGH_VIZ_REPLY_EXEMPT_MIN_PAGE_RANK_SCORE = 66`。

---

## 2. 三条并行链路

| 链路 | 输入 | 决策形式 | 节奏 |
|---|---|---|---|
| `scarecrow` + `botmaker` | **事件**（发帖、关注、改置顶、URL 信誉变更、模型副作用…） | YAML 信封 + condition/action DSL | 近实时（打标 API 本身可能耗时数秒） |
| `abuse-enforcement-service` | **模型已产出的 `score.labels`** | CEL 表达式 YAML，首命中即停 | 请求驱动 |
| `safety-label-user-agg` | 推文安全标签事件流 | Strato 流式聚合，绝对条数 | **故意延迟 10 分钟** |

三条链路都能写账号标签，互相不知道对方存在。排查"为什么被限流"必须三条都看。

---

## 3. 规则语言：读懂一条规则所需的最少知识

### 3.1 物理形态：YAML 信封 + 两段 DSL

`botmaker/src/thrift/com/twitter/botmaker/rule/rule.thrift:6-26`：

```thrift
struct BotMakerRule {
  5:  required string eventType          // 绑定哪个事件
  6:  required string booleanExpression  // condition：布尔门
  7:  required string actionExpression   // action：副作用
  10: optional DateTimeMilliSeconds expiryDate
  14: optional map<string, list<ActionLimit>> actionLimits = {}
}
```

`.bot` 字段一一对应：`id` / `event` / `condition` / `action` / `expiry` / `isActive` / `actionLimits`（`GroxTweetProcessor.bot:1-2,38-40`）。`.df` 是可复用的带类型函数，支持 `params(...)`、默认值、`returnType`（默认 `"Auto"`）、`logged`（`rule.thrift:40-48`）。

**`expiry` 是规则自身的下线时间，不是标签 TTL。** `BBQDuplicateTextProd.bot:75` = `2027-02-21`，`GroxTweetProcessor.bot:38` = `2029-06-14`，而 `ProductionAgatha__FilterOutOrganicNotifications.bot:37` = `+292278994-08-17`（等于永不过期）。把 `expiry` 读成"标签关多久"是最常见的误读。

### 3.2 `MATCHES` 是全串匹配，不是搜索

`botmaker/src/java/com/twitter/botmaker/compiler/RegexCache.java:71-73`：

```java
public boolean matches(Context<?> context, String regex, String str) {
  Pattern pattern = patterns.getUnchecked(Pair.of(regex, Pattern.DOTALL)).get();
  return pattern.matcher(interruptible(context, str, timeoutMilis)).matches();
}
```

调用 Java `Matcher.matches()`（整串），带 `DOTALL`，并有 **1000 ms 正则超时**（`RegexCache.java:151` `int DEFAULT_TIMEOUT_MS = 1000;`）。入口 `botmaker/src/java/com/twitter/botmaker/function/string/RegexMatch.java:45`，文法 `BotMaker.g:137-140`。

**因此 `MATCHES ".*BAD"` = 含 BAD 后缀，`MATCHES "BAD"` = 严格等于 `"BAD"`。规则 3226 正是靠这两级区分处置强度：严格 `"BAD"` → `SPAM`，带后缀的 BAD 变体 → `SPAM_HIGH_RECALL`**（`Tweet_Spam_High_Recall_RTF_All_Bad_URL_Sources.bot:40-46`）。

其余语法要点（`botmaker/src/antlr/com/twitter/botmaker/antlr/BotMaker.g`）：`TRUE`/`FALSE`/`NULL` **必须大写**，小写是禁用关键字（`:84-86`）；反引号包外部符号 `` `AutoExpiringTempSkipList` ``（`:92`）；`:name` 局部变量（`:96`）、`.name` 字段（`:97`）；`$<path/comp>.field(args)` 读 Strato 列（`:190-193`）；`FOREACH`/`for`/`flatmap`/`val`/`with`/`if`/`{a; b; c}`（`:201-222`）；注释 `/* */` 或 `#`（`:80`）。

事件类型共 **91 个** feature 类（`botmaker/scarecrow_features/src/main/java/com/twitter/scarecrow/features/`），公开 20 条规则只用了 9 个：`bqbm_scheduled_queries`（**仓库内无对应 feature 类**）、`url_event`、`url_reputation_change`、`media_update`、`tweet`、`follow`、`user_modification`、`health_side_effect`、`new_send_notification_write`、`grok_share`。`TweetCreate`/`TweetReport`/`UserCreate`/`UserReport`/`Bookmark`/`Favorite`/`Community*`/`AudioSpace*`/`DMReport`/`LoginChallengeAction`/`ArkoseVerifyEvent` 等事件**存在但无公开规则使用**——这些方向的规则被隐藏了。

### 3.3 动作：用 `ActionLevel` 认出真正的处置

`botmaker/src/java/com/twitter/botmaker/function/` 下 **155 个内置函数**，每个带 `ActionLevel` 标注，8 档见 `compiler/ActionLevel.java:3-12`。**真正改动线上可见性的动作被标为 `PROD_TANGIBLE_IMPACT_ACTION`**，这是识别"哪些函数是处置动作"的可靠标记。

| 动作函数 | 落库目标 | 关键语义 | 证据 |
|---|---|---|---|
| `TweetRtfApplyLabel` | ActionIntakeService `AddLabelsV2` | `PROD_TANGIBLE_IMPACT_ACTION`；**「can take *seconds* to return」**，官方建议包 `DoAsync`；13 个参数含 `applicableUsers`（可只作用于部分被 @ 的人）、`score`、`source`、`expiration`（**绝对毫秒时间戳，非 TTL**）、`policyKeys` | `scarecrow/function/ActionIntakeServiceRegistry.scala:21-100`，级别 `:30`，警告 `:33-34`，参数 `:53-67` |
| `TweetRtfRemoveLabel` | 同上 | 撤标 | `ActionIntakeServiceRegistry.scala:102-142` |
| `SetUserLabel` | Gizmoduck | 账号级标签。**第 4 参是到期时刻**，注释原文「expiration AT time in ms; NOTE that this is **NOT TTL** (default = now + 7 days)」；第 5 参 force set | `scarecrow/legacy/ActionerRegistry.scala:12-39`，参数说明 `:29-39` |
| `SetLabel` / `SetLabelWithTtl` | Manhattan labelstore | **同一实现类**；默认 TTL **26 小时** | `scarecrow/legacy/SpamLabelStoreRegistry.scala:106-108`，`:55` |
| `GetLabel` | 同上 | namespace 不得含 `/`；缺失返回 `""` | `SpamLabelStoreRegistry.scala:17-48` |
| `CreateRtpReportAsyncProd` | 人工审核队列 | **只建 review 工单，不打标** | `ViolenceAndGore_ImageModel_MTT.bot:85,99` |
| `WriteUrlVerdictsV2` | URL 信誉库 | 写 verdict + TTL + 匹配模式 | `NSFW_Card_Image_Media_To_URL_Verdict.bot:17` |

防呆：`SetTweetRtfApplyLabelWithExpirationMs.df:2-15` 只有 `:expirationTimeMs > CurrentTimeMs()` 才真的打标，否则只记 `SetLabelWithExpiredTtl` 统计。

### 3.4 计数与限流：三层，全是硬数字

**(a) 规则内 `RateLimited`**（`scarecrow/legacy/function/RateLimited.scala:32-47`）：参数为 `(action, lookback 秒, threshold, alias, default)`。超阈值走 `default`；**没给 default 就抛 `RateLimitedFunctionException`**（`:108-110`）。第 4 参 alias 让多条规则共享同一配额桶。

**(b) 规则级配额 `ActionLimit`**（`rule.thrift:28-38`）：`{quota, periodInMinutes, strategy, version}`，`RateLimitingStrategy = TOKEN_BUCKET(0) | HALT_UNTIL_HUMAN_INTERVENTION(1)`。运行时 `scarecrow/ScarecrowBotMaker.scala:450-482`（`:461` `periodSecs = periodInMinutes * 60`），decider `enable_action_rate_limiter_${appName}_$env`（`:487-496`），熔断态 `waitingForHumanIntervention`（`:498-506`）。Halt 模式下超限会 `setBotActionHaltedState`——**整条 bot 停摆等人工**。计数器名 `"ActionRateLimiter_" + functionName`（`:601-603`）。**`:596-598` 是 fail-open**：`rescue { case _ => func.apply() }`，限流组件挂了照样打标。

**(c) 底层计数原语**：

| 原语 | 精度 / 保留期 | 跨机房 | 证据 |
|---|---|---|---|
| `AddToHLL` / `GetHLLCount` | 默认 precision **60 秒**；默认 TTL **25 小时**，**硬上限 76 天**（超出被截断） | 可跨 DC | `scarecrow/legacy/HllCounterStoreRegistry.scala:26-27,34,93` |
| `IncrementFeatureCountLite` / `GetFeatureCountLite` | 保留 **1 天** | **默认只读本 DC**，下游缓存 1 秒 | `scarecrow/legacy/LimiterRegistry.scala:28-34,75-81` |
| `SetLabelWithTtl` | 默认 **26 小时** | Manhattan | `SpamLabelStoreRegistry.scala:55` |

跨 DC 靠 `.df` 封装：`AddToHLLForDataCenter.df:5-8` 写 `Join(".", GetDataCenterName, :namespace)`；`GetHLLCountFromDataCenters.df:5-9` **同时读 `atla.<ns>` 与 `pdxa.<ns>` 再相加**。这就是 NSFW 账号升级判定必须绕这一层的原因——单机房计数会漏。

其他可用信号：`GetUserCredV2`（`StratoRegistry.scala:120-135`）、`GetUserHealthScores(userId, List(modelNames))`（`:137-161`）、`FollowerCount`/`IsFollowing`（`FlockRegistry.scala:13-34,36-61`）、URL verdict `GOOD/BAD/UNKNOWN`（`UrlVerdictRegistry.scala:67`）、外部维护名单 `GetLongList(BMSymbol)`（`scarecrow/function/ListRegistry.scala:14-26`）。

---

## 4. 20 条公开规则速查表

### 4.1 URL 信誉类（6 条）——可见规则里最大的一族

| 规则 / id | 事件 | 触发条件与阈值 | 产出 |
|---|---|---|---|
| `Tweet_Spam_High_Recall_RTF_All_Bad_URL_Sources` / 3226 | `url_event` | `Count(redirectionChain) > 0 && GetUrlVerdictForSingleChain(...) MATCHES ".*BAD"`（`:6-7`）；作者取原推作者否则 `tcoUserId`（`:8-24`） | **严格 `"BAD"` → `SPAM`；否则 → `SPAM_HIGH_RECALL`**（`:40-46`）；`DoAsync`（`:36`）+ Guano 备注（`:39`） |
| `Tweet_Search_Blacklist_RTF_All_UNSAFE_URL_Sources` / 20789 | `url_event` | `MATCHES ".*UNSAFE"`（`:6`） | 一次打 **4 个标签**，各自幂等检查：`SEARCH_BLACKLIST`(`:35`)、`UNSAFE_URL`(`:41`)、`DO_NOT_AMPLIFY`(`:47`)、`MALICIOUS_URL`(`:53`) |
| `LQ_Tweets_With_LQ_URL_Verdict_At_Mention_To_NonFollower` / 5239 | `url_event` | `!isReply && !isRetweet`（`:8-9`）+ verdict `MATCHES "LOW_QUALITY"`（`:22`）+ **被 @ 的人里至少 1 个不关注作者**（`:23-27`） | `SPAM_HIGH_RECALL`（`:46`） |
| 同上 `_v2` / 6754 | `url_event` | 末跳不在 `Set("GOOD","WHITELIST")`（`:8`）且链上任一 URL `== "LOW_QUALITY"`（`:9`） | `SPAM_HIGH_RECALL`（`:16`）；规则 expiry 2028-02-08（`:20`） |
| `rtf_tweets_on_unsafe_verdict` / 20790 | `url_reputation_change` | `verdict == "UNSAFE" && (action == "PUT" \|\| "DELETE")`（`:4-7`）；`GetSlugsForUrl → GetTweetIdsForSlugs` **回溯历史推文**（`:11-13`） | PUT 打 4 标签（`:19-22`），**DELETE 撤 4 标签**（`:24-27`） |
| `tweet_rtf_or_unrtf_on_bad_verdict` / 2002 | `url_reputation_change` | `verdict == "BAD"` + PUT/DELETE（`:4-5`）；PUT 需重查链 `Contains(:verdict,"BAD") && !Contains(...,"WHITELIST") && !Contains(...,"GOOD")`（`:13-20`） | 打/撤 `SPAM`（`:31,33`） |

5239 的门槛原文（`LQ_Tweets_With_LQ_URL_Verdict_At_Mention_To_NonFollower.bot:23-27`）：

```
    Count(Filter(
      :victimId,
      !IsFollowing(GetUserIdFromScreenName(:victimId), :authorId),
      GetMentionedScreenNames(GetTweetText(tweetId))
    )) > 0 &&
```

**门槛是 `> 0`，@ 一个陌生人都算，没有数量下限。但必须同时带低质链接**——纯 @ 骚扰（无链接）的生产规则不可见。

### 4.2 账号行为类（2 条）——置顶推文连坐

| 规则 / id | 事件 | 条件 | 产出 |
|---|---|---|---|
| `PinnedLowQualityOrBadUrl` / 20719 | `user_modification` | `pinnedTweetIds.simple.after` 存在、非空、**且与 `.before` 不同**（`:6-14`）；展开 URL 后 `GetReputationV2(GetUrlResolutions(:urls))` 任一 verdict `== "BAD" \|\| == "LOW_QUALITY"`（`:15-24`） | `SetUserLabel(spammerId, "SPAM_HIGH_RECALL", "[bot/20719] PinnedLowQualityOrBadUrl", CurrentTimeMs() + OneWeekInSecs*1000)`（`:36-41`）→ **账号级 7 天** |
| `FollowFromActorWithPinnedLowQualityOrBadUrl` / 20732 | `follow` | **发起关注者**的置顶推文含 BAD/LOW_QUALITY 链接（`:7-29`） | 同样账号级 `SPAM_HIGH_RECALL` **7 天**（`:40-45`），日志文案「Restricting notifications.」 |

### 4.3 内容模型类（8 条）

| 规则 / id | 事件 | 阈值（原文数字） | 产出 |
|---|---|---|---|
| `NsfwTweetMediaProcessor` / 22418 | `health_side_effect`（`subEvent == "nsfw_tweet_media"`，`:4`） | `label == "3" && score > 0.99`（`:7-12`）；`label == "3"`（`:16-19`）；`label == "4"`（`:23-26`） | `ApplyNsfwUserLabel` → `NSFW_NEAR_PERFECT` / `NSFW_HIGH_PRECISION` / `NSFW_HIGH_RECALL`（`:12,19,26`），**并触发账号级升级判定**（第 8 节） |
| `nsfw_user_write_user_label` / 22358 | `health_side_effect`（`nsfw_user`） | `GetUser != NULL && !IsTestUser`（`:4-6`） | `ApplyNsfwUserLabelOrCreateReport(userId, "NSFW_HIGH_PRECISION"/"NSFW_HIGH_RECALL", ...)`（`:9-10`） |
| `ViolenceAndGore_ImageModel_MTT` / 20616 | `media_update` | 标注身份 `domainId == 140 && groupId == 34 && entityId == 1199070453920223232`（`:33-35`）；**`TWEET_IMAGE` precision `> 0.6`**（`:10,37`）；**`TWEET_VIDEO` raw_score `>= 0.95`**、**`AVATAR_IMAGE` `>= 0.85`**、**`BANNER_IMAGE` `>= 0.85`**（`:12-14,40-41`） | 头像/横幅 → **只建人工工单** `CreateRtpReportAsyncProd(..., "MEDIA_PROACTIVE_REVIEW", ...)`（`:83-86`）；推文媒体且非高信誉 → `TweetRtfApplyLabel("GORE_AND_VIOLENCE_HIGH_PRECISION", tweetId)`（`:88-97`）；否则转人工（`:99`） |
| `AgathaSpamProduction__ApplySearchTopTweetLabel` / 20998 | `tweet` | `GetUserHealthScores(spammerId, List("AgathaAllSpamReportsPerFav","AgathaSpamSuspended"))`（`:8-14`）；**`allSpamReportsPerFavScore > 0.9975 \|\| spamSuspendedScore > 0.98`**（`:14`） | `AGATHA_SPAM` 推文标签，**TTL 7 天**（`:22-26`） |
| `NSFW_Card_Image_Media_To_URL_Verdict` / 7429 | `media_update` | `category == "CARD_IMAGE" && IsNearPerfectNsfw`（`:6-7`） | `WriteUrlVerdictsV2(Set(:cardUrlLastHop), "NSFW_CARD_IMAGE", 86400 * 7, "EXACT_URL_MATCH", ...)`（`:17`）→ **URL verdict 7 天**；不再 NSFW 则撤销（`:20-27`） |
| `NSFW_Card_Image_URL_to_Tweet_Verdict` / 7413 | `url_reputation_change` | verdict `NSFW_CARD_IMAGE` + PUT/DELETE（`:7-8`） | 先写 1 小时防抖 `SetLabel("NSFW_Url", entity, "NSFW_Card_Image_Url", 1*60*60, FALSE)`（`:12`）；**`:tweetSafeguard = 5000`**（`:20`）→ 单次最多给 **5000 条**未打标推文补 `NSFW_CARD_IMAGE`（`:22-24`）；DELETE 撤销（`:30-31`） |
| `NSFW_Grok_Generated_Image_To_URL_Verdict` / 24493 | `media_update` | `category == "GROK_GENERATED_IMAGE" && IsHighPrecisionNsfw`（`:6-7`） | `SetLabelWithTtl("GrokMediaNsfwDetection", entityId, "NearPerfectNsfw"\|"HighPrecisionNsfw", OneDayInSecs * 75)`（`:14-26`）→ **75 天** |
| `NSFW_Grok_Share` / 24603 | `grok_share` | 任一 grokMediaId 带 `GrokMediaNsfwDetection` 标签（`:7-10`）；构造 `https://x.com/i/grok/share/<shareId>`（`:14`） | `WriteUrlVerdictsV2(..., "NSFW_CARD_IMAGE", 86400*7, ...)`（`:18`） |

**NSFW 三档尺度方向不同**，真身在 `.df` 里：

| 档位 | 判据 | 阈值 | 证据 |
|---|---|---|---|
| near-perfect | `precisionNewNsfw >=` | **0.999** | `IsNearPerfectNsfwNewModelLogic.df:3-4` |
| high-precision | `precisionNewNsfw >=` | **0.95** | `IsHighPrecisionNsfwNewModelLogic.df:3-4` |
| high-recall（非视频） | **`recallNewNsfw <=`** | **0.8568428** | `IsHighRecallNsfwNewModelLogic.df:3-9` |
| high-recall（视频） | **`recallNewNsfw <=`** | **0.6** | 同上 |

**注意 high-recall 档的不等号是反向的：recall 分越低越危险，与 precision 相反。** 把 `<= 0.8568428` 读成"精确率不足 85.7% 才放过"是错的。暴力/血腥模型则**视频要 0.95、图片只要 0.6**（`ViolenceAndGore_ImageModel_MTT.bot:10,12`），图片打标门槛显著更低。

### 4.4 批量重复文本类（2 条）

| 规则 / id | jobName 白名单 | 限流 | 产出 |
|---|---|---|---|
| `BBQDuplicateTextProd` / 21711 | `bbq_duplicate_text_unigrams`、`bbq_duplicate_text_characters_cjk`（`:8-9`） | **100000 / 60s**（`:38-39`） | `COPYPASTA_SPAM`（`:46`）+ 24h 去重标记（`:47`）+ 每人每天 1 条 Guano 备注（`:15,55-59`） |
| `BBQDuplicateTextRepliesProd` / 21599 | `bbq_duplicate_text_unigrams_replies`、`bbq_duplicate_text_characters_replies_cjk`（`:8-9`） | **100000 / 60s**（`:37-38`） | `COPYPASTA_SPAM`（`:44`），**无 Guano 备注** |

去重标记 TTL 默认 **86400 秒**：`SetBigQuerytoBotmakerLabel.df:2-3` `params(String :jobName, String :entityId, Long :ttlSecs = 86400)`，命名空间 `BQ_to_BM_namespace.df:2` = `"bq_to_bm_namespace"`。

---

## 5. 三条完整规则原文

### 5.1 批量重复文本 → `COPYPASTA_SPAM`（`BBQDuplicateTextProd.bot:1-77`，id 21711）

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

action 段要点（同文件）：`:19-22` 三重去重（已处理过 / 已有 `COPYPASTA_SPAM` / card2 是 `promo_video_convo`|`promo_image_convo` 广告卡）；`:30-33` 四类作者豁免；`:38-39` **`val :rateLimitThreshold = 1000 * 100;` `val :rateLimitTimePeriod = OneMinuteInSecs;`** → **每 60 秒最多 10 万条**；`:46-47` 打标 + 写 24h 去重标记；`:55-59` 给作者写 Guano 备注，`:15` `maxGuanoNotes = 1`；`:42-69` 整段包在 `RateLimited(..., jobName, {Log("BBQDuplicateTextProd_rate_limited", ...)})` 里，**超限只记日志、丢弃本批**。

**`entityType == "tweetIdCluster"` 说明上游 BigQuery 作业已把全站推文按文本聚成簇，botmaker 只负责给簇里每条推文打标。判定重复的算法（unigram / CJK 字符）在 BigQuery 侧，不在本仓库**——"重复到什么程度算重复"不可见，可见的只有处置侧 10 万/分钟的闸门。

### 5.2 模型分 → 账号标签 + 6 天疲劳（`ProductionAgatha__FilterOutOrganicNotifications.bot:1-39`，id 21278，全文）

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

**触发点是"要给别人发通知"这一刻，不是发帖时。** 三个 Agatha 模型分**任一**超阈值即命中：`AgathaSpamSuspended > 0.99`、`AgathaAllSpamReportsPerFav > 0.999`、`AgathaSpamReportsPerFav > 0.999`（后两者是"举报数/点赞数"比值模型）。产出账号标签 `AGATHA_SPAM_TOP_USER` **TTL 7 天**，同时写 **6 天疲劳标记**，同一账号 6 天内不会被这条规则重复处置。疲劳命名空间按规则 ID 隔离：`CreateRemediationFatigueNamespace.df:2` = `Concat(RemediationFatigueLabel, "_", ToString(RULE_ID))`，常量 `RemediationFatigueLabel.df:2` = `"REMEDIATION_FATIGUE_LABEL"`。

### 5.3 Grox 模型 → 高风险回复标签 14 天（`GroxTweetProcessor.bot:3-30`，id 25026）

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

**`spamScore >= 0.97` 是唯一模型阈值**；额外豁免"**自己回复自己的主帖**"（`:15,22`）——自问自答不算高风险回复。标签 `RISKY_HIGH_VIZ_REPLY` **TTL 14 天**。**这个标签的实际作用面是通知，不是 For You，见第 10 节。**

---

## 6. 反直觉的行为触发点

这一节是本篇最容易被误判的部分：**很多处置不是"发帖时"评估的，而是被一个看似无关的动作触发的。**

| 你的动作 | 实际发生的事 | 证据 |
|---|---|---|
| **换置顶推文** | 条件显式比较 `before`/`after`，只在置顶变化时评估；展开置顶里的 URL 查信誉，任一 BAD/LOW_QUALITY → **账号级 `SPAM_HIGH_RECALL` 7 天** | `PinnedLowQualityOrBadUrl.bot:6-14,36-41` |
| **关注别人** | 触发的是**对你自己账号**的审查：检查你的置顶推文链接 → 同样账号级 7 天 | `FollowFromActorWithPinnedLowQualityOrBadUrl.bot:7-29,40-45` |
| **@ 一个不关注你的人 + 带低质链接** | 门槛 `> 0`，**一个人就够**，非回复非转推 → 推文 `SPAM_HIGH_RECALL` | `LQ_...NonFollower.bot:8-9,23-27,46` |
| **给别人发通知（你的互动触发了通知）** | 这一刻才跑 Agatha 三分模型 → 账号 `AGATHA_SPAM_TOP_USER` 7 天 | `ProductionAgatha__FilterOutOrganicNotifications.bot:2,18-20,32` |
| **删掉链接 / 链接被洗白** | `url_reputation_change` 的 DELETE 分支**回溯撤销历史推文标签** | `rtf_tweets_on_unsafe_verdict.bot:11-13,24-27`；`tweet_rtf_or_unrtf_on_bad_verdict.bot:33` |

**URL 信誉变更会回溯改写历史推文的标签，并且可撤销。** 这是"删了链接/链接被洗白后限流解除"的代码依据，也是唯一可见的自动撤标路径。

### 6.1 Grok 生成图 → 分享链接 → 转发者连坐

一条完整可见的因果链：

```
Grok 生成 NSFW 图（IsHighPrecisionNsfw）
  → 24493 给媒体写 GrokMediaNsfwDetection 标签，TTL 75 天
  → 用户点"分享"，24603 把 https://x.com/i/grok/share/<shareId>
     写成 URL verdict "NSFW_CARD_IMAGE"，TTL 7 天（86400*7，EXACT_URL_MATCH）
  → 7413 收到 url_reputation_change，回溯给最多 5000 条含该链接的历史推文
     补 NSFW_CARD_IMAGE 推文标签
```

证据：`NSFW_Grok_Generated_Image_To_URL_Verdict.bot:6-7,14-26` → `NSFW_Grok_Share.bot:7-10,14,18` → `NSFW_Card_Image_URL_to_Tweet_Verdict.bot:7-8,20-24`。

**注意精确性：24603 写入的 verdict 是 `NSFW_CARD_IMAGE`，不是 `BAD`。** 因此它不会经 3226（要求 `MATCHES ".*BAD"`）产出 `SPAM`/`SPAM_HIGH_RECALL`；连坐落点是 `NSFW_CARD_IMAGE` 推文标签（消费端 `visibility-filtering/rules/tweet_rules.rs:679-684` 等）。**但"谁转发这个链接谁被连带打标"这个结论成立，且媒体侧记忆长达 75 天。**

---

## 7. abuse-enforcement-service：模型分驱动的处置档位

不消费事件，消费模型已产出的 `score.labels`，用 CEL 表达式 YAML 做**首命中**决策。Rust 实现，规则通过 `include_str!` 编译进二进制（`service-lib/src/rules.rs:13-14`），CEL 编译在 `:129`。`enforcement_user.yaml:1` 注明「mirrored from GrowthBook dynamic config; last sync **2026-10-20T01:49:10Z**」——**线上真值在 GrowthBook，仓库是快照**。

### 7.1 只有三类动作，**没有 read-only**

`service-lib/src/decision.rs:1-41`：

```rust
Decision::{Skip(String), Act(Vec<ActionSpec>)}
ActionSpec::{SuspendUser{perm, policy}, AddLabelsV2{labels, ttl_msec},
             AddPostLabelsV2{labels, ttl_msec}, Arkose, Captcha, SpamLivenessCheck}
```

**全部动作只有三类：打标 / 挑战验证 / 封禁。`READ_ONLY` 只作为被消费的作者标签存在（`author_rules.rs:218`），本服务不产出它。**

去重分类 `decision.rs:27-40`，常量 `service-lib/src/dedup_cache.rs:11-15`（0/1/2/3/4）：`CLASS_SUSPEND_PERMANENT` / `CLASS_SUSPEND` / `CLASS_CHALLENGE`（Arkose|Captcha|SpamLivenessCheck 归为一类）/ `CLASS_LABEL`。**同类动作短期内不重复下发。** 封禁策略只有两种：`types/src/action_control.rs:201-205` `SuspensionPolicy::{PlatformManipulation, Cse}`（Cse = 儿童性剥削，永久封）。

### 7.2 分级阶梯 `suggested()`

`types/src/action_control.rs:398-416` 原文：

```rust
pub fn suggested(entity: ControlEntity, row: LevelRow) -> Vec<PageAction> {
    match (entity, row) {
        (ControlEntity::User, LevelRow::Low) => vec![PageAction::LivenessCheck {}],
        (ControlEntity::User, LevelRow::Mid) => vec![
            PageAction::LivenessCheck {},
            PageAction::SpamHighRecall { lifetime: Lifetime::Days7 },
        ],
        (ControlEntity::User, LevelRow::High) => vec![PageAction::SUSPEND],
        (ControlEntity::Post, LevelRow::Mid) => vec![PageAction::PostSpamHighRecall {
            lifetime: Lifetime::Days30,
        }],
        (ControlEntity::Post, LevelRow::High) => vec![PageAction::PostSpamHighRecall {
            lifetime: Lifetime::Permanent,
        }],
        (ControlEntity::Post, LevelRow::Low) | (_, LevelRow::Missing) => vec![],
    }
}
```

| 实体 | Low | Mid | High |
|---|---|---|---|
| **账号** | 活体检测 | 活体检测 + `SpamHighRecall` **7 天** | **封禁**（`perm: false`，`PlatformManipulation`，`:314-317`） |
| **推文** | **无动作** | `SpamHighRecall` **30 天** | `SpamHighRecall` **永久** |

`Lifetime` → 毫秒：`action_control.rs:190-192`（`Days7 = 7*86_400_000`、`Days30 = 30*86_400_000`、`Permanent = None`）。`PageAction` 全集 `:276-294`。落地映射 `service-lib/src/action_control.rs:144-190`：`SpamHighRecall → AddLabelsV2["SpamHighRecall"]`、`PhoenixSkip → AddLabelsV2["ClientEventPhoenixSkip"]`、`PostSpamHighRecall → AddPostLabelsV2["SpamHighRecall"]`、**`HideReply → AddPostLabelsV2["RiskyHighVizReply"]`**（`:142` 常量）、`SuspendAuthor → SuspendUser{perm:false, PlatformManipulation}`。Gizmoduck 序号：`service-lib/src/gizmoduck_labels.rs:1-11` `SpamHighRecall` = **23**，`ClientEventPhoenixSkip` = **118**。可打的推文标签白名单 `action_control.rs:229-234` `PAGE_POST_LABELS = ["NsfaHighPrecision","NsfaLimitedInventory","NsfwHighPrecision","SoftNsfw"]`。

### 7.3 Low/Mid/High 怎么定：precision 下限 **+ 二项检验**

`types/src/action_control.rs:63-69`：`Low => 0.70`、`Mid => 0.85`、`High => 0.95`。**但这只是 precision 下限，还要过人工抽检样本量检验。** `service-lib/src/confidence.rs:138-164`：

```rust
fn read_meets(reads: u32, humans: u32, floor: f64) -> bool {
    upper_tail(reads - humans, reads, floor) <= ALPHA
}
```

`ALPHA = 0.05`（`:19`），即**二项分布上尾检验**：在"真实精确率 = floor"的假设下，观察到 `reads - humans` 次非人类判定的概率必须 ≤ 5%。`supported_level`（`:166-186`）取满足 `lower_bound >= floor && read_meets(...)` 的**最高档**。

单测钉死了最小样本量（`confidence.rs:294-312`，测试名 `the_memo_read_counts_meet_their_floors_and_one_fewer_does_not`）：

| 目标档 | floor | 0 次人工推翻 | 1 次 | 2 次 | 少 1 个样本就降档 |
|---|---|---|---|---|---|
| **High** | 0.95 | **≥ 59 reads** | ≥ 93 | ≥ 124 | `ev(0.95, 58, 0)` → 只到 Mid |
| **Mid** | 0.85 | **≥ 19 reads** | ≥ 50（3 次推翻） | ≥ 68（5 次推翻） | `ev(0.85, 18, 0)` → 只到 Low |
| **Low** | 0.70 | **≥ 9 reads** | — | — | `ev(0.70, 8, 0)` → **None** |

**`ev(0.99, 10, 0)` 即使 precision 下限 0.99，样本只有 10 个也只能认 Low。** `ev(0.70, 50, 25)` → None（人工推翻一半）。

证据护栏：`confidence.rs:12-19` `DEFAULT_EVIDENCE_MAX_AGE_DAYS = 30`、`DEFAULT_FACTORY_EVIDENCE_MAX_AGE_DAYS = 365`、`CLOCK_SKEW_MS = 300_000`（5 分钟）、`MAX_READS = 100_000`；`types/src/action_control.rs:153` `EVIDENCE_OVERRIDE_MAX_MS = 7 * 86_400_000`（人工覆盖证据 7 天失效）。拒绝条件（`confidence.rs:166-186,193-199`）：非有限/越界下限、`reads == 0`、`reads > 100k`、`humans > reads`、证据过期或来自未来。`LevelRow` 映射 `confidence.rs:29-37`：`0→Missing, 1→Low, 2→Mid, 3→High`，其他值 → Missing + unknown。

### 7.4 账号处置流水线（`enforcement_user.yaml`，190 行，首命中）

前置豁免（skip）：`:6-10` 白名单；`:12-16` `!user.present`；`:19-24` 粉丝数（**mock**）；`:26-33` cred（**mock**）；`:144-148` 已封禁；`:150-154` 已停用。

| 行号 | 触发标签（`score.labels` 成员） | 动作 | TTL |
|---|---|---|---|
| `:36-38` | `anchor_campaign_suspend` | 封禁 `perm:false, PlatformManipulation` | — |
| `:39-41` | `anchor_campaign_user` | `AddLabelsV2 ["SpamHighRecall"]` | **无 ttl = 永久** |
| `:43-45` | `anchor_campaign_suspend_cse` | 封禁 **`perm:true, Cse`** | 永久 |
| `:47-49` | `panda_reports_embedding_v10_rough_spam` | 封禁 `perm:false` | — |
| `:51-53` | `bb1_post_spam_bot_suspend` | 封禁 | — |
| `:55-63` | `bb1_post_spam_bot_bounce` | `act_all`：`SpamHighRecall` + `spam_liveness_check` | **`2592000000` = 30 天**（`:62`） |
| `:65-67` | `bb1_reply_spam_bot_suspend` | 封禁 | — |
| `:69-77` | `bb1_reply_spam_bot_bounce` | `SpamHighRecall` + 活体 | 30 天（`:76`） |
| `:79-81` | `bb1_user_suspend` | 封禁 | — |
| `:83-91` | `liveness_check_and_spam_high_recall_7d` | `SpamHighRecall` + 活体 | **`604800000` = 7 天**（`:90`） |
| `:93-98` | `spam_high_recall_7d` | `SpamHighRecall` | 7 天（`:98`） |
| `:100-108` | `bb1_user_bounce` | `SpamHighRecall` + 活体 | 30 天（`:107`） |
| `:112-116` | `llm_slop_user` **且已有** `SpamHighRecall` | **skip**（不叠加） | — |
| `:118-123` | `llm_slop_user` | `SpamHighRecall` | **7 天**（`:123`） |
| `:125-129` | `SpamEmbeddingMajorityPoster` 且已有标签 | skip | — |
| `:131-136` | `SpamEmbeddingMajorityPoster` | `SpamHighRecall` | **30 天**（`:136`） |
| `:139-142` | `spam_liveness_check_required` | 活体检测 | — |
| `:156-161` | `enforcement_cusp_arkose` && !`enforcement_threshold_reached` | **Arkose 挑战** | — |
| `:163-168` | `enforcement_cusp_captcha` && !`enforcement_threshold_reached` | **Captcha** | — |
| `:170-175` | `enforcement_cusp_liveness` && !`enforcement_threshold_reached` | 活体检测 | — |
| `:177-182` | `impersonation_scam_classifier_v1_suspend` | 封禁 `perm:false` | — |
| **`:184-189`** | **`when: "true"`（兜底）** | **封禁 `perm:false, PlatformManipulation`** | — |

**账号流水线的兜底是封禁。** `rules.rs:105-120` 强制要求必须有 `when: true` 终结项，否则 `EvalError::NoMatch`。**能进入账号处置流水线、且没被前面任何豁免/轻处置拦下的，默认封号。**

**`llm_slop_user`（AI 灌水）→ 7 天、`SpamEmbeddingMajorityPoster`（embedding 判定"绝大多数发帖是 spam"）→ 30 天，这是可见的 AI 生成内容处置档位。** 两者都有"已有 `SpamHighRecall` 就跳过"的前置项，不叠加延长。

### 7.5 推文处置流水线（`enforcement_post.yaml`，82 行）

前置 skip：`:5-21` 推文/作者白名单、作者不存在；`:23-28` 粉丝数、`:30-37` cred（均为 mock），两者都带 `&& !score.skip_author_credibility_prechecks`。**`skip_author_credibility_prechecks` 是个可绕过信誉豁免的开关**，CEL 上下文定义 `rules.rs:211-237`（`ScoreCel{labels, model_version, skip_author_credibility_prechecks}`）。

| 行号 | 触发 | 动作 | TTL |
|---|---|---|---|
| `:39-44` | `llm_slop_post` | `AddPostLabelsV2 ["RiskyHighVizReply"]` | **30 天** |
| `:46-51` | `gibberish_post`（乱码） | `SpamHighRecall` | 30 天 |
| `:53-58` | `fast_reply_spam_post`（**秒回 spam**） | `SpamHighRecall` | 30 天 |
| `:60-62` | `anchor_campaign_post` | `SpamHighRecall` | **永久** |
| `:65-69` | `SpamEmbeddingPtosDistilled` | `SpamHighRecall` | **永久** |
| `:71-76` | `cse_reports_embedding_v2` | **封禁作者 `perm:true, Cse`** | 永久 |
| **`:78-82`** | **`when: "true"` 兜底** | **skip（`post_no_actionable_label`）** | — |

**对比关键：推文流水线兜底是"不动"，账号流水线兜底是"封禁"。** 且推文侧可以直接封作者（`:71-76`，CSE 场景）。

### 7.6 全局护栏

| 护栏 | 值 | 证据 |
|---|---|---|
| 灰度分桶 | `ROLLOUT_ALL_BP = 10_000`（万分比），FNV-1a 哈希 | `types/src/action_control.rs:11,13-37` |
| 控制模式 | `ControlMode::{Rules, Recording, Live, Rows}`，`Recording` 是影子模式 | `:158-163` |
| 强制降级 | kill_switch / stale_snapshot / safety_checks_changed / wrong_entity / unreadable / outside_rollout 一律降为 Missing | `service-lib/src/action_control/levels.rs:202-319`，`:321-348`，`:350-400`；原因枚举 `confidence.rs:248-263` |
| 安全前置断言 | 运行时校验 YAML 前置 skip 与代码一致 | `service-lib/src/safety_checks.rs:19-40`（USER_CHECKS）、`:42-68`（POST_CHECKS）、`:93-156`、`:167-175` |
| 全局每日总量 | `WINDOW_SECS = 86_400`、`SNAPSHOT_INTERVAL_SECS = 60`、`SCAN_LIMIT = 200_000`；pkey `global_rate_limit` / `global_rate_limit:post` | `service-lib/src/sliding_window.rs:14-18,36-38` |
| 全局桶 | `GLOBAL_BUCKET_USER_ID = 1`、`GLOBAL_BUCKET_POST_ID = 10`；`try_record` **fail-open 可配** | `service-lib/src/limiter.rs:9-10,112-117` |
| **Head guard（自动刹车）** | **`DEFAULT_MIN_DECIDED_APPEALS = 30`**、**`DEFAULT_OVERTURN_WINDOW_HOURS = 72`**、`MAX_OVERTURN_WINDOW_HOURS = 168` | `types/src/head_guard.rs:7-11`，结构 `:23-29,33-56` |
| 其他节奏 | `MAX_RETRIES = 5`、`SWITCH_LISTS_POLL = 200ms`、`CONFIG_REFRESH_INTERVAL = 15s` | `service-lib/src/lib.rs:140,2904,3547` |

**Head guard 语义：某条处置规则在 72 小时窗口内、至少 30 个已裁决申诉中，翻案率超过 `max_overturn_rate`，就自动限制该规则每小时/每天的动作数（`max_actions_per_hour` / `max_actions_per_day`）。这是"规则误伤率高会被自动掐掉"的机制。**

---

## 8. 推文标签如何升级为账号标签：两套独立机制

### 8.1 NSFW 专用：HLL 计数 + 疲劳（botmaker 侧）

`botmaker-rules/scarecrow/derived-feature/ApplyNsfwUserLabel.df`（54 行）是**唯一可见的"推文标签累积 → 账号标签"完整实现**：

- `:3` 命名空间 `"NsfwUser"`；`:5-13` 三个 HLL topic：`NSFWNearPerfectImagePosted` / `NSFWHighPrecisionImagePosted` / `NSFWHighRecallImagePosted`
- `:15-17` **`:hllPrecision = 60`（秒）、`:hllTtl = 26`（小时）**，注释原文「one day + 2 hours (should match lookback sec in GetHLLCountFromDataCenters)」
- **核心阈值 `:30-38`**：

```
      GetHLLCountFromDataCenters(
        :nsfwUserHllNamespace,
        :hllTopic,
        ToString(:userId),
        OneDayInSecs,
        :hllPrecision,
        0,
        :hllSlice
      ) > 2
```

**→ 24 小时内跨机房去重计数 > 2，即 ≥ 3 条 NSFW 推文，才升级为账号标签。** 命中记 `MoreThan2InADay` 统计（`:40`）。

- `:41-44` **每用户每标签每天只处置一次**：疲劳命名空间 `Concat("Fatigue", RULE_ID, :label)`，`SetLabelWithTtl(..., "TRUE", DayInSecs)`
- `:45` 才调 `ApplyNsfwUserLabelOrCreateReport`

### 8.2 四分支策略：打标 vs 转人工

`ApplyNsfwUserLabelOrCreateReport.df`（93 行）：

| 分支 | 条件 | 结果 | 行号 |
|---|---|---|---|
| 默认 TTL | — | `:labelExpiry = CurrentTimeMs() + SevenDaysInSecs * 1000` = **7 天** | `:2` |
| ① 近期被人工撤标 | `NsfwUserLabelRemoved` 时间戳 > `CurrentTimeMs() - (3 * ThirtyDaysInSecs * 1000)` → **过去 90 天内人工撤过 NSFW 标签** | 进入"上报而非打标"分支 | `:3,7-8` |
| ② 高信誉 + 低粉丝 NSFW 信号 | `IsHighPageRankUser && NsfwConsumerFollowerScoreDouble < 0.1` | 同上（疑似误判） | `:11-15` |
| ③ 灰 V / 名单 / 金 V | gray-verified、`AutoExpiringTempSkipList`、gold-verified | 同上 | `:17-19` |
| 工单频率限制 | 命名空间 `ApplyNsfwUserLabelReported` | **每用户每周最多 1 次工单**（`OneWeekInSecs`） | `:22-25` |
| 工单落地 | 进入上报分支后**还要**满足高信誉/名单/灰V/金V | `CreateRtpReportAsyncProd(:entity, :userId, "MEDIA_PROACTIVE_REVIEW", 2241808, :reason)`；否则**既不建单也不打标** | `:32-38`，否则 `:46-48` |
| ④ 普通用户 | 非高信誉、非名单、非灰 V | `SetUserLabel(..., :labelExpiry)` = **7 天** | `:52-64` |
| ⑤ 高信誉但未被上面拦住 | 且 `!GetUser(:userId).safety.nsfw_admin` | `SetUserLabel(..., CurrentTimeMs() + OneDayInSecs * 3 * 1000)` = **3 天** | `:65-72` |
| ⑥ NSFW 管理员 | `safety.nsfw_admin == true` | **完全跳过** | `:73-81` |

**两条差别待遇是明写的：高信誉账号 NSFW 标签只关 3 天、普通账号关 7 天（`:64` vs `:72`）；90 天内被人工撤过标的账号，之后只走上报分支、不自动打标。** 后者是申诉成功后的长期保护，比第 9 节的 hold 更久。

### 8.3 通用聚合：Strato 流处理，**绝对条数，不是比例**

`safety-label-user-agg/postToUserLabelRules.strato`（459 行）。条件结构 `:11-17` `PostLabelCountCondition{windowSize, minimumMatchingPosts, maxPostAgeDays, mediaOnly, postLabels}`；规则结构 `:34-43` `UserLabelRule{id, enabled, triggerPostLabels, maxTriggerPostAgeDays, condition, applyUserLabel, userLabelTtlDays, exclusions}`；标签选择器支持 `anyOf`/`allOf` 的 DNF 组合（`:6-9,19-25`）。

判定逻辑（`:266-284`）：

```
    .take(condition.windowSize)
    ...
    .size >= condition.minimumMatchingPosts
```

**取该作者最近 `windowSize` 条推文，数其中"够新且命中标签"的条数，≥ `minimumMatchingPosts` 就升级。是绝对计数，不是百分比——不存在"30% 推文被标记就封号"这种规则。** `isRecentPost` 用 Snowflake 时间戳判定（`:77-80`），标签名归一化去掉 `_` 并转小写（`:82-88`）。`mediaOnly` 时扫描量放大 4 倍（`:161-174`，`mediaOnlyScanMultiplier = 4`）。多规则命中同标签时**取最大 TTL**（`:294-319`）。

配置护栏（`:96-107`，校验在 `:199-204,229-233,241`）：

| 护栏 | 值 |
|---|---|
| `allowedApplyUserLabels` | **只允许 `POSSIBLY_NSFW_ACCOUNT`、`NSFW_HIGH_PRECISION`** |
| `maxConfiguredRules` | 10 |
| `maxConditionGroups` / `maxConditionsPerGroup` | 10 / 10 |
| `maxConfiguredWindowSize` | **10** |
| `maxConfiguredMinimumMatchingPosts` | **11** |
| `maxConfiguredPostAgeDays` | **60** |
| `maxConfiguredUserLabelTtlDays` | **7** |

**即：这套通用聚合器目前只能产出 NSFW 相关账号标签，窗口最长看最近 10 条推文，账号标签最长 7 天。它不是通用的"spam 推文累积封号"引擎。**

出厂默认规则（`:360-428` `defaultRulesJson`）：

| id | triggerPostLabels | windowSize / minimumMatchingPosts | maxPostAgeDays | applyUserLabel | userLabelTtlDays | exclusions |
|---|---|---|---|---|---|---|
| `possibly_nsfw_account`（`:364`） | `NSFW_HIGH_PRECISION` \| `SOFT_NSFW` | **10 / 11**（`:373-374`） | 60 | `POSSIBLY_NSFW_ACCOUNT` | **7**（`:387`） | nsfwUser / nsfwAdmin / highPageRankOrGreyBadge = true；已有 `NSFW_HIGH_PRECISION`、`POSSIBLY_NSFW_ACCOUNT` |
| `nsfw_high_precision`（`:396`） | `NSFW_HIGH_PRECISION` | **5 / 3**（`:405-406`） | 60 | `NSFW_HIGH_PRECISION` | **7**（`:419`） | nsfwAdmin = true；已有 `NSFW_HIGH_PRECISION` |

**`windowSize: 10` 配 `minimumMatchingPosts: 11` 在数学上不可满足（`.take(10).size >= 11` 永远 false），所以出厂的 `possibly_nsfw_account` 规则永远不会触发。** 结合 `12.34`/`12345.67` 的 mock 注释，这大概率是同源的反 gaming 处理（**推测，非官方声明**）；线上真值由 feature switch 覆盖：`:430-432` `safety_understanding_post_to_user_label_rules`。**能确定生效的是第二条：最近 5 条推文里有 3 条 `NSFW_HIGH_PRECISION` → 账号 `NSFW_HIGH_PRECISION` 7 天。**

执行器 `safetyLabelToUserLevelAggregationV2Processor.strato`（137 行）：`:19` **只处理 `actionType == Applied`**（撤标不触发降级）；`:29-39` 拉作者 + `platform-manipulation/isHighPageRankV2` + `isGreyBadge`；`:62-67` 从 `profile/timelines/userTimeline/edgeBySource` 倒序分页拉 `maxScanSize` 条；`:68-73` 转推要解析原推、读 `visibility/baseTweetSafetyLabelMap`；`:92-106` 通过 `hmli/gizmoduckSetUserLabels` 写入，**`byUser = "Grox"`、`source = Some("Grox")`**，`expiresAtMsec = now + ttlDays`。

---

## 9. 申诉成功后的豁免期：**天数不可知**

### 9.1 机制

`abuse-enforcement-service/service-lib/src/overturn_hold.rs:1-4` 模块原文：

> 「Overturn-hold gate: the last precheck before a suspend (or a gated label) is dispatched. It exists so we do not re-apply an enforcement that a human reviewer already overturned on appeal.」

调用点 `service-lib/src/lib.rs:794-840`（`gated_actions`、`strip_held_labels`、skip 状态）。

### 9.2 时长完全由 DB 决定，仓库里没有天数

`abuse-ledger-service/src/sql.rs:3-7` 原文：

```sql
SELECT user_id, hold_id, head, expires_at, case_group_id, reason, action_kind, label
FROM ledger.enforcement_holds
WHERE user_id = ANY($1::bigint[]) AND cleared_at IS NULL AND expires_at > now()
AND (action_kind = 'suspend' OR (action_kind = 'label' AND label = ANY($2::text[])))
```

**时长完全由 `expires_at` 决定，该字段由外部申诉系统写入。** 佐证：

- `abuse-ledger-service/src/sql.rs:53-60` 单测断言本服务**不含任何 INSERT/UPDATE/DELETE/ALTER/DROP/CREATE**——纯只读服务。
- `abuse-ledger-service/src/repo.rs:36-51` `HoldRepo` trait 只有 `lookup` / `contract_check` / `ping`（+ 状态查询）。
- `README.md:335` 原文：「when an enforcement is overturned on appeal, `abuse-enforcement-service` does not re-apply that action for a fixed period, **set per appeal queue**.」

**结论：豁免期按申诉队列配置，不是全局常量，具体天数不可见。任何"申诉成功后 X 天不被限流"的说法都无法从本仓库证实。** 可证实的只有：豁免期内该动作被完全跳过。`reason` 取值可见 `"appeal_overturned"`（`service-lib/src/ledger_contract_fixtures.rs:14`、`overturn_hold.rs:2178`）与 `"manual"`（`overturn_hold.rs:418`）。

### 9.3 闸门配置（全部硬数字）

`overturn_hold.rs:19-47`：`CONFIG_KEY = "overturn_hold_gate"`、`LOOKUP_PATH = "/v1/holds/lookup"`、`STATUS_HOLD_OVERTURNED = "hold_overturned"`、`STATUS_HOLD_LOOKUP_FAILED = "hold_lookup_failed"`、`CONNECT_TIMEOUT = 200ms`、`MAX_BODY_BYTES = 64KiB`、**`DEFAULT_TIMEOUT_MS = 200`**、**`DEFAULT_POSITIVE_CACHE_SECS = 60`**、`MIN/MAX_TIMEOUT_MS = 10/5000`、`MAX_POSITIVE_CACHE_SECS = 3600`、**`BREAKER_FAILURES = 5`**、**`DEFAULT_BREAKER_OPEN = 10s`**、`CACHE_MAX_WEIGHT = 100_000`。

| 项 | 默认值 | 证据 |
|---|---|---|
| 模式 | `GateMode::{Off, Shadow, Enforce}`，**默认 `Off`** | `:51-56`，`:150-163` |
| 查询失败 | `OnProbeError::{Allow, Skip}`，**默认 `Allow`（fail-open，照样处置）** | `:78-82`，`:150-163` |
| 作用范围 | kinds = `[Suspend]`，labels 为空 → **默认只保护封禁，不保护标签** | `:150-163`；标签要保护须显式加白名单 `:404-415` `gates_label(name)` |
| 永久封禁例外 | 只有「case-group 白名单为空」或「`reason == "manual"`」或「`case_group_id` 在 `perm_suspend_case_groups` 里」时才被 hold 拦住 | `overturn_hold.rs`（`hold_applies`） |
| Hold 结构 | `{user_id, hold_id, head, expires_at, case_group_id, reason, action_kind, label}` | `:429-451`；`GateKind` 常量 `:102-125` |
| 服务端限额 | `MAX_USER_IDS = 100`、`MAX_LABELS = 32` | `abuse-ledger-service/src/api.rs:21-24` |

**运营含义：申诉成功 → 外部系统写入 hold → 在 `expires_at` 之前，同一条处置规则不会再次封你/给你打指定标签。但这道闸在开源快照里默认 Off、默认只管封禁、查询失败默认放行。**

---

## 10. 标签到底作用在哪个界面

**"限流"和"shadow ban"的力度差别，取决于两件事：受众（audience）和挂载的界面（level）。**

- **`NonAuthors`** = 除作者本人外全部丢弃（**粉丝也看不到**）。
- **`NonFollowers`** = 作者 + 粉丝可见，只丢陌生人。
- 两者绝不可混用。

| 标签 | 层级 | 受众 / 动作 | 规则定义 | 挂载界面 |
|---|---|---|---|---|
| `SPAM_HIGH_RECALL` | 账号 | **NonAuthors** → `drop_post(UnspecifiedReason)` | `author_rules.rs:204-209` | `OON_AUTHOR_LABEL_DROPS`（`levels.rs:101-108`）→ **For You**（`levels.rs:351`） |
| `READ_ONLY` / `COMPROMISED` / `IMPERSONATION_HIGH_PRECISION` | 账号 | NonAuthors | `author_rules.rs:218-223` 等 | 同上 → **For You** |
| `DO_NOT_AMPLIFY` / `ABUSIVE_HIGH_RECALL` | 账号 | **NonFollowers** | `author_rules.rs:239-244` | 同上 → **For You** |
| `SPAM_HIGH_RECALL` | 推文 | **NonAuthors** → `drop_post(PossiblyUndesirable)` | `tweet_rules.rs:944-949` | `OON_POST_DROPS`（`levels.rs:215-220`）→ **For You**（`levels.rs:378`） |
| `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | 推文 | NonFollowers → `PossiblyUndesirable` | `tweet_rules.rs:930-935,937-942` | 同上 → **For You** |
| **`RISKY_HIGH_VIZ_REPLY`** | 推文 | NonFollowers → `UnspecifiedReason` | `tweet_rules.rs:1029-1034` | **只在通知面**：`levels.rs:259`（MENTION）、`:275`（MEDIA_TAGGED）。**未挂 `TIMELINE_HOME_RECOMMENDATIONS`** |
| `DUPLICATE_CONTENT` / `DUPLICATE_MENTION` / `ABUSIVE` / `UNTRUSTED_URL` / `DOWNRANK_SPAM_REPLY` / `SMYTE_SPAM_TWEET` / `LOW_QUALITY` | 推文 | 见各规则 | `tweet_rules.rs:961-1020` | `LOW_QUALITY_AND_UQF_DROPS`（`levels.rs:190-199`）→ **只在通知面**（`levels.rs:258,297`） |
| `NOT_GRADUATED` / `AGATHA_SPAM_TOP_USER` / `ENGAGEMENT_SPAMMER` / `BLINK_WORST` / `DOWNRANK_SPAM_REPLY` | 账号 | NonFollowers | `author_rules.rs:246-283` | `NOTIFICATION_AUTHOR_LABEL_DROPS`（`levels.rs:132-143`）→ **只在通知面**（`levels.rs:238,246,270,284,310`） |
| `COPYPASTA_SPAM` / `SEARCH_BLACKLIST` | 推文 | — | botmaker 产出 | **`visibility-filtering/` 内无任何消费者**（搜索侧） |

**两条必须记住的纠正：**

1. **Grox 的 `RISKY_HIGH_VIZ_REPLY`（规则 25026，`spamScore >= 0.97`，TTL 14 天）作用是让被你回复的人收不到回复通知，不是把回复从 For You 里删掉。** 同理 `enforcement_post.yaml:39-44` 的 `llm_slop_post` → `RiskyHighVizReply` 30 天也是通知面。
2. **`NOT_GRADUATED`、`AGATHA_SPAM_TOP_USER`、`ENGAGEMENT_SPAMMER` 在公开规则挂载里只抑制通知，未挂进 For You。** 说"未毕业账号的内容对非粉丝完全不可见"超出了公开代码能支撑的范围——**能支撑的是"对非粉丝的通知被丢弃"**。真正在 For You 里让账号近乎全隐藏的是 `SPAM_HIGH_RECALL`（NonAuthors）。

---

## 11. 延迟与 TTL 全表

### 11.1 三种触发模式并存

| 模式 | 载体 | 延迟证据 |
|---|---|---|
| **事件驱动（近实时）** | Scarecrow 消费事件，91 个事件类型 | 无显式延迟；但 `ActionIntakeServiceRegistry.scala:33-34` 明写打标 API **「can take *seconds* to return」**，故多数规则包 `DoAsync`（`ProductionAgatha...bot:27`、`Tweet_Spam_High_Recall...bot:36`） |
| **批量（BigQuery → BotMaker）** | `bqbm_scheduled_queries`，仅 BBQ 两条规则 | 调度周期在 BigQuery 侧，**不可见**；可见的是每批 10 万条/60 秒闸门（`BBQDuplicateTextProd.bot:38-39`）与 24h 去重（`SetBigQuerytoBotmakerLabel.df:2`） |
| **流式延迟聚合** | `safety-label-user-agg` Strato forwarder | **`safetyLabelToUserLevelAggregationV2Forwarder.strato:18` `delay = 10.minutes`**；**`:19` `slo = { maxLag = 20.minutes }`**；`:5` topic `vf_tweet_safety_labels_event_prod`；`:7` consumerGroupId `safety-label-user-level-aggregation-v2`；`:15` `forwardEventsFrom = LocalZoneOnly` |

**账号级 NSFW 聚合是"故意延迟 10 分钟、SLO 上限 20 分钟"的批流处理，不是实时。** 这给撤标/申诉留了一个天然缓冲窗口。

### 11.2 读取侧缓存（决定"多久生效 / 多久消失"）

| 层 | 参数 | 值 | 证据 |
|---|---|---|---|
| VF 进程内热键缓存 | `TTL` | **10 秒** | `safety-label-source/source.rs:15` |
| VF 回复预算 | `REPLY_ALLOWANCE` | **5 ms** | `source.rs:16` |
| 过期标签处理 | `label_is_live` / `drop_expired_labels` | **读取时过滤已过期标签** | `source.rs:38-57` |
| Dragonfly 刷新 | `REFRESH_AFTER` / `REPEAT_AFTER` | **60 s / 30 s** | `safety-label-source/dragonfly.rs:30-31` |
| Dragonfly 写入 TTL | `WRITE_TTL_SECS` | **24 h** | `dragonfly.rs:34` |
| 命中缓存 TTL | `found_ttl` | **24 h**（switch `rust_vf_safety_label_cache_found_ttl_secs`） | `dragonfly.rs:63,97-98` |
| **未命中缓存 TTL** | `not_found_ttl` | **1 h**（switch `rust_vf_safety_label_cache_not_found_ttl_secs`） | `dragonfly.rs:64,99-100` |
| 最小 TTL | `MIN_TTL` | 60 s | `dragonfly.rs:44` |
| 队列/批量 | `REPEAT_QUEUE` / `FILL_QUEUE_KEYS` / `FILL_BATCH_KEYS` | 500,000 / 10,000 / 100 | `dragonfly.rs:32-44` |
| 后端超时 | `request_timeout` / `connect_timeout` | **20 ms / 5 s** | `safety-label-source/connect.rs:232,269` |
| 预热 | `WARM_CHANNEL_CAPACITY` / `WARM_LINGER` / `WARM_FETCH_MAX_KEYS` | 1024 / **500 ms** / 50 | `safety-label-source/warmer.rs:9-11` |

**关键运营结论：两个 TTL 的方向是反的，别记错。** `found_ttl = 24h` 缓存的是「**有**标签」，`not_found_ttl = 1h` 缓存的是「**没有**标签」（`dragonfly.rs:248-253` 的 `is_live` 按 `Status::Found` / `NotFound` 分别取 TTL）。所以：

- **标签被撤掉**（申诉成功）→ 旧的「有标签」条目还在，硬上界 **24h**；
- **标签被加上** → 旧的「无标签」条目还在，硬上界 **1h**。

但这两个是 **`is_live` 硬过期上界，不是保证延迟**：`due_refresh`（`dragonfly.rs:160-170`）会让 step 0 且年龄 ≥ `REFRESH_AFTER`(60s) 的条目触发**一次**刷新（step→1，不是持续刷新），`refresh_cutoff_ms` 还能强制重填早于 cutoff 的条目。完整的刷新调度/serving 循环未在仓库内，**真实恢复时延无法从本仓库确定**。热键 10 秒 TTL 是热点推文的最快生效路径。

### 11.3 标签 TTL 汇总（全部来自代码原文）

| 标签 | 层级 | TTL | 证据 |
|---|---|---|---|
| `AGATHA_SPAM_TOP_USER` | 账号 | **7 天** + **6 天疲劳** | `ProductionAgatha__FilterOutOrganicNotifications.bot:32,34` |
| `SPAM_HIGH_RECALL`（置顶 / 关注触发） | 账号 | **7 天** | `PinnedLowQualityOrBadUrl.bot:40`；`FollowFromActorWithPinnedLowQualityOrBadUrl.bot:44` |
| `AGATHA_SPAM` | 推文 | **7 天** | `AgathaSpamProduction__ApplySearchTopTweetLabel.bot:25` |
| `RISKY_HIGH_VIZ_REPLY`（Grox） | 推文 | **14 天** | `GroxTweetProcessor.bot:29` |
| `COPYPASTA_SPAM` | 推文 | **无 TTL**（永久，靠 24h 去重防重复） | `BBQDuplicateTextProd.bot:46-47` |
| `SPAM` / `SPAM_HIGH_RECALL`（URL） | 推文 | **无 TTL**，靠 `url_reputation_change` DELETE 撤销 | `Tweet_Spam_High_Recall...bot:41,44`；`tweet_rtf_or_unrtf_on_bad_verdict.bot:33` |
| `SEARCH_BLACKLIST` / `UNSAFE_URL` / `DO_NOT_AMPLIFY` / `MALICIOUS_URL` | 推文 | 无 TTL，可撤销 | `Tweet_Search_Blacklist...bot:35-53`；`rtf_tweets_on_unsafe_verdict.bot:24-27` |
| NSFW 账号标签（普通） | 账号 | **7 天** | `ApplyNsfwUserLabelOrCreateReport.df:2,64` |
| NSFW 账号标签（高信誉） | 账号 | **3 天** | `ApplyNsfwUserLabelOrCreateReport.df:72` |
| `POSSIBLY_NSFW_ACCOUNT` / `NSFW_HIGH_PRECISION`（聚合） | 账号 | **7 天**（上限亦为 7） | `postToUserLabelRules.strato:387,419,106` |
| `SpamHighRecall`（enforcement 7d 档） | 账号 | **604800000 ms** | `enforcement_user.yaml:90,98,123` |
| `SpamHighRecall`（enforcement 30d 档） | 账号 | **2592000000 ms** | `enforcement_user.yaml:62,76,107,136` |
| `SpamHighRecall`（anchor / embedding 档） | 账号 / 推文 | **永久（无 ttl）** | `enforcement_user.yaml:39-41`；`enforcement_post.yaml:60-69` |
| `RiskyHighVizReply`（`llm_slop_post`） | 推文 | **30 天** | `enforcement_post.yaml:39-44` |
| `GrokMediaNsfwDetection` | 媒体 | **75 天** | `NSFW_Grok_Generated_Image_To_URL_Verdict.bot:18,25` |
| `NSFW_CARD_IMAGE` URL verdict | URL | **7 天**（`86400*7`） | `NSFW_Card_Image_Media_To_URL_Verdict.bot:17`；`NSFW_Grok_Share.bot:18` |
| `NSFW_Url` 防抖标记 | URL | **1 小时** | `NSFW_Card_Image_URL_to_Tweet_Verdict.bot:12` |
| Manhattan 通用 `SetLabel` | — | **默认 26 小时** | `scarecrow/legacy/SpamLabelStoreRegistry.scala:55` |
| HLL 计数 | — | 默认 **25 h**，上限 **76 天** | `HllCounterStoreRegistry.scala:27,34` |
| `FeatureCountLite` | — | **1 天** | `LimiterRegistry.scala:75-81` |
| BQ→BM 去重 | — | **86400 s** | `SetBigQuerytoBotmakerLabel.df:2` |

时间常量（均在各自 `.df:2`）：`OneDayInSecs`/`DayInSecs` = 86400、`OneDayInMillis` = 86400000、`OneWeekInSecs`/`SevenDaysInSecs` = 604800、`ThirtyDaysInSecs` = 2592000、`OneMinuteInSecs` = 60。

---

## 12. 信誉豁免与新号

### 12.1 `IsHighPageRankUser`：所有豁免的总开关

`botmaker-rules/scarecrow/derived-feature/IsHighPageRankUser.df:4-18` 关键行：

```
    val :userCredScore = TryOrElse(GetUserCredV2(:userId).score, NULL);
    val :predictedHighPageRank = {
      val :userLabels = TryOrElse(GetUserLabels(:userId), EmptyStringSet);
      Contains(:userLabels, "PREDICTED_HIGH_PAGE_RANK")
    };
    val :pageRankCriteria = Coalesce(:userCredScore, -1) >= HighPageRankThreshold || :predictedHighPageRank;
    val :followerCountFromGizmoduck = Coalesce(FollowerCountFromGizmoduck(:userId), 0);
    val :fallbackFollowerCountCriteria = :followerCountFromGizmoduck > 25000;
    val :usePageRankCriteria = :userCredScore != NULL || :predictedHighPageRank;
```

- **`HighPageRankThreshold.df:2` = `54`**（已验证生产默认值）
- 判定：`UserCredV2.score >= 54` **或** 带 `PREDICTED_HIGH_PAGE_RANK` 标签；**两者都拿不到时才退化为 `followers > 25000`**
- 结果用 `CacheGet` 缓存（`:3`）

分数来源 `user-cred-v2/UserCredV2.scala:10-18`：`ScoreSlope = 7.07`、`ScoreIntercept = 165.2`，**`rawScore = 165.2 + 7.07 * ln(mass)`**（mass ≤ 0 时为 0），`score = clamp(rawScore, 0, 100)`。反解 score ≥ 54 需 `ln(mass) >= (54-165.2)/7.07 = -15.73`，即 mass ≥ 1.48e-7——**这是个极低的 PageRank 质量门槛，说明"高信誉"判定主要靠 `PREDICTED_HIGH_PAGE_RANK` 标签，而非纯分数**。

其他豁免身份：`IsUserGrayVerified.df:4-7` = `ToLower(GetUser(:userId).safety.verified_type) == "government"`（**灰 V = 政府**）；`IsUserGoldVerified.df:4-7` = `== "business"`（**金 V = 企业**）。`FollowerCountFromGizmoduck.df:4` = `GetUser(:userId).counts.followers`。

### 12.2 每条规则都有的四件套豁免

20 条规则里反复出现的同一组条件（`BBQDuplicateTextProd.bot:30-33`、`ProductionAgatha__FilterOutOrganicNotifications.bot:7,22-24`、`GroxTweetProcessor.bot:9,16-20`、`LQ_...NonFollower.bot:28-31`）：

```
!IsTestUser(:author) &&
!IsHighPageRankUser(:author) &&
!Contains(GetLongList(`AutoExpiringTempSkipList`), :author) &&
!IsUserGrayVerified(:author)
```

**反过来读就是普通新号的处境：高信誉账号、政府灰 V、内部测试号、以及一个外部维护的自动过期临时白名单（`AutoExpiringTempSkipList`，经 `scarecrow/function/ListRegistry.scala:14-26` 的 `fetcher20.getSimpleListLongValues` 读取，名单内容不在仓库）里的账号，被系统性排除在这些打标规则之外。普通新号没有这层保护。**

### 12.3 home-mixer 两道"新号"过滤：**代码在，默认关；而且指的是观众**

**这两道过滤不能用来解释任何真实的限流问题。** 两个独立原因：

**(a) 开关默认 false。**

| 开关 | 默认值 | 证据 |
|---|---|---|
| `EnableNewUserMinEngagementFilter`（`rust_home_mixer_enable_new_user_min_engagement_filter`） | **`false`** | `home-mixer/params/param.rs:937-941` |
| `EnableNewUserSoftNsfwFilter`（`rust_home_mixer_enable_new_user_soft_nsfw_filter`） | **`false`** | `home-mixer/params/param.rs:967-971` |

**(b) `NewUserMinEngagementFilter` 里的"新号"是观众（`query.user_id`），不是作者。**

```rust
// home-mixer/filters/new_user_min_engagement_filter.rs:70-77
fn within_account_age(query: &ScoredPostsQuery) -> bool {
    let max_age_secs = query.params.get(NewUserMinEngagementFilterMaxAccountAgeSecs);
    duration_since_creation_opt(query.user_id)   // query.user_id = 观众
        .map(|age| age < Duration::from_secs(max_age_secs))
        .unwrap_or(false)
}
```

**即使打开，它限制的也是"一个刚注册的观众能看到多少陌生人的内容"，不是"一个新作者能被分发多少"。** OON-only 的作用范围是真的：`should_keep` 在 `candidate.in_network != Some(false)` 时直接返回 true（`new_user_min_engagement_filter.rs:60-63`）。

阈值本身是真实默认值，但**因为开关关着，全部不生效**：

| 参数 | 默认值 | 状态 | 证据 |
|---|---|---|---|
| `NewUserMinEngagementFilterMetric` | `"fav"` | 代码在，默认关 | `param.rs:946` |
| `NewUserMinEngagementFilterUseRatio` | `true`（除以曝光） | 同上 | `param.rs:952`（switch 名 `:951`） |
| `NewUserMinEngagementThreshold` | `0.004` | 同上 | `param.rs:955-958` |
| `NewUserMinEngagementFilterMaxAccountAgeSecs` | `1800`（30 分钟） | 同上 | `param.rs:961-964` |
| `NewUserMinEngagementFilterMaxResurrectionAgeSecs` | `1800` | 同上 | `param.rs:985-988` |
| `NewUserSoftNsfwFilterMaxAccountAgeSecs` | `604800`（7 天） | 同上 | `param.rs:973-976` |
| `NewUserSoftNsfwFilterMaxScoringSeqLength` | `100` | 同上 | `param.rs:979-982` |

第二道过滤的逻辑（`home-mixer/filters/new_user_soft_nsfw_filter.rs:13-27`）：仅 For You 非话题场景 + 账号年龄 < 7 天 + 打分序列长度 < 100；`:38-40,52` 移除关注外且 `soft_nsfw == true` 的推文。**同样默认关。**

指标定义供参考：`:92-104` fav/engagement/view，可选除以曝光取比率；`:106-113` engagement = fav + reply + repost + quote。

### 12.4 `NOT_GRADUATED`

`visibility-filtering/rules/author_rules.rs:246-251`：`NOT_GRADUATED_USER_LABEL_DROP_UNSPECIFIED`，受众 **NonFollowers**，`AuthorHasLabel(AuthorLabel::NotGraduated)` → `drop_post(DropAs::UnspecifiedReason)`。**生产该标签的规则未公开**（第 1.2 节），**且公开挂载里它只作用于通知面**（第 10 节）。"注册多久算毕业"完全不可见。

---

## 13. 可直接引用的硬结论

1. **打标是"模型分 + 硬阈值"，不是模糊综合判断**：Grox `spamScore >= 0.97`（`GroxTweetProcessor.bot:8`）、Agatha `> 0.99 / 0.999 / 0.999`（`ProductionAgatha...bot:18-20`）、NSFW near-perfect `>= 0.999`（`IsNearPerfectNsfwNewModelLogic.df:3`）、血腥图片 `> 0.6` / 视频 `>= 0.95`（`ViolenceAndGore_ImageModel_MTT.bot:10,12`）。
2. **`MATCHES` 是全串匹配**（`RegexCache.java:71-73`），`".*BAD"` 与 `"BAD"` 是两级不同强度，分别产出 `SPAM_HIGH_RECALL` 与 `SPAM`（`Tweet_Spam_High_Recall...bot:40-46`）。
3. **URL 信誉变更会回溯改写历史推文标签，并且可撤销**（`rtf_tweets_on_unsafe_verdict.bot:11-13,24-27`）。
4. **换置顶推文会触发全账号复检并可致账号级 7 天限流**（`PinnedLowQualityOrBadUrl.bot:6-14,36-41`）；**关注别人也会触发对自己的审查**（`FollowFromActorWithPinnedLowQualityOrBadUrl.bot:7-29,40-45`）。
5. **@ 陌生人 + 低质链接 = 限流，门槛是 1 个人**（`LQ_...NonFollower.bot:23-27,46`）；纯 @ 骚扰规则不可见。
6. **账号级聚合是"最近 N 条里绝对 M 条"，不是比例**；通用聚合器只允许产出 NSFW 类账号标签，窗口 ≤ 10、TTL ≤ 7 天（`postToUserLabelRules.strato:96-107,266-284`）。生效默认是 **5 条里 3 条**（`:405-406`）；另一条 **10/11 数学上永不触发**（`:373-374`）。
7. **NSFW 升级账号标签需 24h 内跨机房 ≥ 3 条**（`ApplyNsfwUserLabel.df:30-38`），每人每标签每天最多处置一次（`:41-44`）；高信誉账号 3 天、普通账号 7 天（`ApplyNsfwUserLabelOrCreateReport.df:64,72`）。
8. **处置只有三类：打标 / 挑战验证（Arkose、Captcha、活体）/ 封禁，没有 read-only 动作**（`decision.rs:1-41`）。账号流水线兜底是封禁（`enforcement_user.yaml:184-189`），推文流水线兜底是不动（`enforcement_post.yaml:78-82`）。
9. **High 档需要 precision 下限 ≥ 0.95 且 ≥ 59 次人工抽检 0 推翻**（`action_control.rs:65-67` + `confidence.rs:162-163,296`）；样本不够自动降档，`ev(0.99,10,0)` 只认 Low。
10. **home-mixer 的两道"新号"过滤默认关闭，且 `NewUserMinEngagementFilter` 的"新号"指观众而非作者**（`param.rs:937-941,967-971` + `new_user_min_engagement_filter.rs:70-77`）。**不要用它们解释新号没曝光。** 真正系统性豁免的是高信誉（cred ≥ 54 或 `PREDICTED_HIGH_PAGE_RANK`，无分时 followers > 25000）、政府灰 V、临时白名单账号（`IsHighPageRankUser.df:4-18`、`HighPageRankThreshold.df:2`）。
11. **`RISKY_HIGH_VIZ_REPLY` 抑制的是通知，不是 For You 分发**（`levels.rs:259,275`；未挂 `TIMELINE_HOME_RECOMMENDATIONS`）。
12. **申诉豁免期存在但天数不可知**，且闸门默认 Off、默认只保护封禁、查询失败 fail-open（`overturn_hold.rs:150-163`、`README.md:335`、`abuse-ledger-service/src/sql.rs:3-7`）。
13. **撤标后恢复可见有缓存滞后，方向别记反**：`Found`（有标签）条目 TTL 24h、`NotFound`（无标签）1h（`dragonfly.rs:63-64,248-253`）；另有 `REFRESH_AFTER=60s` 的**一次性**刷新（`:160-170`）。24h/1h 是硬上界不是保证延迟，真实恢复时延不可从本仓库确定。

**三个必须标注的不可知项**：① 申诉豁免期具体天数（DB `expires_at`，按申诉队列配置）；② `abuse-enforcement-service` 的粉丝/PageRank 豁免阈值（`12.34`、`12345.67` 是官方 mock）；③ 协同操纵、刷互动、发帖速率、hashtag 滥用、`NOT_GRADUATED` 的判定逻辑（`README.md:333,444-447` 承认未公开）。