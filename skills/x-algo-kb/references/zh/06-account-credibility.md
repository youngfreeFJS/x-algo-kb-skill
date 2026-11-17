# 06 · 账号信誉与内容识别模型

> 证据基准：`xai-org/x-algorithm` commit `a284320b66a9dce35e6f5d6b052ee308eeb12326`，路径相对仓库根。
> 生产侧 `user-cred-v2/`、`agatha/`、`bdsm/`、`grox/`、`media-model-proxy/`、`clip/`、`adult-content/`、`pnsfwmedia/`；消费侧 `botmaker-rules/`、`visibility-filtering/`、`safety-label-user-agg/`、`abuse-enforcement-service/`。
> 全文区分三类数值：**生产真值**（54 / 66 / 0.95 / 0.999…）、**代码存在但未公开或默认关闭**（bdsm 操作点、starter-pack 闸门）、**哨兵或 mock 值**（`9.99` / `999999` / `12.34` / `12345.67`）。第三类**不是**线上阈值，不可用于解释任何真实处罚。

---

## 1. user-cred-v2：账号权重就是这一个数

`user-cred-v2/UserCredV2.scala:3-19` 输出结构体只有 `id / mass / score`，映射写死在代码里：

```
score = clamp(165.2 + 7.07 · ln(mass), 0, 100)      # mass <= 0 时 score = 0
```

`ScoreSlope = 7.07`（`:10`）、`ScoreIntercept = 165.2`（`:11`）。**mass 每翻 e 倍（≈2.718）分数 +7.07；每 +10 分需要 mass 翻 ≈4.11 倍。** 反解 `mass = exp((score − 165.2) / 7.07)`（下表是按公式算出的量级参考，不是仓库常量表）：

| score | 对应 mass | 用途 |
|---|---|---|
| 0 | ≤ 7.1e-11 | 无 mass / 被 clamp |
| **54** | ≈ 1.48e-7 | `IsHighPageRankUser` 豁免线（生产真值） |
| 55 | ≈ 1.70e-7 | VIT（very-important-tweeter）统计线，仅快照健康度 |
| **66** | ≈ 8.06e-7 | grox 回复垃圾豁免线（生产真值） |
| 90 | ≈ 2.40e-5 | `gte90Count` 统计线，仅快照健康度 |
| 100 | ≥ 9.88e-5 | 上限 clamp |

**低分本身不触发任何处罚——它只是"豁免权的缺失"。** 全仓库对 user-cred 分数的**公开数值消费点只有两处：54 和 66**（`botmaker-rules/scarecrow/derived-feature/HighPageRankThreshold.df:2`、`grox/flows/reply_spam/constants.py:9`）；处罚服务里还有第三处比较，但阈值是 mock（§9）。没有"user-cred 低 → 乘一个降权系数"这样的代码：低于线的账号只是不享受"转人工 / 短 TTL / 直接跳过"，随后被 agatha / grox / bdsm / 媒体模型的判定**原样执行**。

---

## 2. mass 怎么来：唯一可操作的部分

### 2.1 只有两类边，且无权重

| 边类型 | 定义与约束 | 证据 |
|---|---|---|
| 关注边 | `FlockFollowsJavaDataset` 快照，只保留 `stateId == 0`（`ValidState = 0`） | `UserCredV2App.scala:24-30`；`Edge.scala:11-19` |
| 互动边 | `EngagementTypes = Set(InteractionType.Favorite, InteractionType.Retweet)`——**只有点赞和转推**，不含回复、点击、停留 | `UserCredV2App.scala:79-82` |
| 互动窗口 | **7 天**，排除自互动与 `engagingUserId <= 0`；边方向构造为 `互动者 → 推文作者` | `UserCredV2Config.scala:25`；`UserCredV2App.scala:84-100` |
| 边校验 | `getPageRankGraph` 用 `_.asTuple.swap` 做两次 join：**目标必须是有效用户、源必须 active** | `UserCredV2App.scala:287-318` |
| 传播 | `mass / neighbourCount`，**无任何边权衰减**；`Edge(sourceId, destinationId)` 结构体里没有 weight 字段 | `UserCredV2App.scala:320-390`；`Edge.scala:11-19` |

**净效果：权重从互动者/关注者流向被互动者/被关注者。** 这就是"被高权重账号点赞/关注才有用"的机制来源；你自己的动作不会给自己加 mass。

### 2.2 反串通：关联账号之间的边被整条删除

`UserCredV2App.scala:102-118` 读 `AccountExpansionInvestigationsScalaDataset`（≤7 天）拿到"关联账号对"（判定为同一人控制的小号群），对**关注边和互动边都做 left-join 并整条丢弃**。**小号互关、小号互赞，在图上等于不存在。**

### 2.3 teleport 种子集：一半是认证账号，没有人工白名单

`UserCredV2App.scala:141-193` `computeTeleportWeights`：

```
teleport   = (1 − beta) · uniform + beta · engagement        # beta 默认 0.5
uniform    = 在 !isNearZero && isPremium 的账号上均匀分布
engagement = 每个互动者归一化 engagerMass.mass × count / totalCount，按目标求和后全局归一化
```

`beta` 默认 **0.5** 且强制 ∈[0,1]（`UserCredV2Config.scala:35`、`:36-38`）。`isPremium` 定义（`user-cred-v2/ValidUserInfo.scala`）：

```
isPremium = isBlueVerified || isGrayVerified || isGoldVerified || isVerifiedOrg || isVOAffiliate
```

**本篇最硬的结论：蓝标 / 灰标 / 金标 / 机构认证 / VO 关联账号直接构成 teleport 种子集的一半——认证账号是全网权重的"源泉"。** 非认证账号只能靠**被认证账号或高 mass 账号点赞/转推/关注**间接获得 mass。买蓝标不等于直接加权重，但它把你放进了 mass 的注入端。

### 2.4 受限账号是吸收态

| 状态 | 在图里的处理 |
|---|---|
| `restricted` / `deactivated` / `suspended` / `erased` | `ValidUserInfo.fromFlatUser` 返回 `None` → **整体不进图**，既非节点也不传播（`user-cred-v2/ValidUserInfo.scala`） |
| `userState == 1`（`NearZeroState`，near-zero） | 仍是节点，但只进 `allUserPipe` 不进 `activeUserPipe` → **可以接收 mass，永不向外传播**（`UserCredV2App.scala:287-318`） |

**near-zero 账号是质量黑洞：它给别人的点赞不再传递任何权重。** 找一堆被限流的号互赞在图上完全无效。

---

## 3. 迭代、收敛与发布闸门

`user-cred-v2/UserCredV2Config.scala:30-45` 全部默认值：

| 参数 | 默认值 | 含义 |
|---|---|---|
| `jump_prob`（alpha） | **0.2** | teleport 概率 |
| `threshold` | **0.001** | L1 差分收敛阈值 |
| `max_iterations` | **50** | 最大迭代轮数 |
| `engagement_teleport_beta` | **0.5** | 互动 / 均匀混合比 |
| `vit_threshold` | **55.0** | VIT 判定线（健康度统计） |
| `gate_row_delta` / `gate_vit_delta` | 0.05 / 0.05 | 行数 / VIT 数相对波动上限 |
| `gate_mass_min` / `gate_mass_max` | **0.99 / 1.005** | 总质量守恒区间 |

迭代式（`UserCredV2App.scala:320-390`）：`distributed(u) = mass(u)/outDegree(u)`；`missingMass = 1 − Σdistributed`（dangling）；`jumpMass(v) = p(v)·alpha + p(v)·missingMass·(1−alpha)`；`mass_new(v) = normalMass(v)·(1−alpha) + jumpMass(v)`；`diff = Σ|mass_new − mass_old|`（L1）。

- 循环条件 `diff > 0.001 && curIteration + 1 < 50`（`:246-270`），每轮后按 `mass / Σmass` 归一化（`:272-285`），初值每个有效用户 1.0（`UserMass.scala:11-13`）。
- **热启动优先用上一版快照的 mass**（`:120-139`）：这是每天增量迭代的链，不是每天从零重算——**掉权重和恢复都不会一夜发生。**
- 每日调度（`:518-534`），产出 HDFS `UserCredV2ScalaDataset` + Manhattan `UserCredV2ManhattanScalaDataset`，写 `UserCredV2Scores{score, mass, snapshotTimestampMsec}`（`:453-506`）。
- **快照隔离闸门**（`user-cred-v2/SnapshotSafeguard.scala:21-89`）：`GateMetrics(rows, massSum, vitCount = score ≥ 55 人数, gte90Count = score ≥ 90 人数)`，三检查 `G1_row_count` / `G2_mass_sum` / `G3_vit_count`。任一超限则整个快照**进隔离区不发布**、线上继续用旧分数（`UserCredV2App.scala:392-430`，除非显式 `skip_gate`）。

---

## 4. agatha：别人如何对待你的内容

### 4.1 唯一公式与分母口径

`agatha/scalding/labels/rate_based_labels/RateBasedLabels.scala:44-56`（四个标签共用）：

```
score = (interaction + 0.1) / (interaction + favs + 0.1 / prior)
```

`smoothingParam = 0.1`（`:60`），`prior = posSum / (posSum + negSum)` 为全局先验（`agatha/scalding/labels/LabelUtil.scala:41-44`）。这是**加性平滑的贝叶斯比率**，不是裸比值——0 赞 0 举报的新号不会因分母为 0 而爆炸。样本量被显式保留（`positiveCount = interaction`、`totalCount = interaction + favs`，`:50-55`），下游 `agatha/hub/agatha/builder/Builder.scala:27-36`、`predict/Predict.scala:27-49` 用 `smoothedRatio.getOrElse(positiveCount / totalCount)` 喂 PMI。

**分母只用网外点赞**：`agatha/scalding/labels/favs/Favs.scala:15-68` 排除自赞与测试账号，再对**双向关注集合**做 anti-join，只留陌生人的赞。**你自己粉丝的点赞不能稀释你的举报率**——靠粉丝刷赞压低 `ReportsPerFav` 在这套特征里无效。

### 4.2 四个标签的分子与窗口

| labelName | 分子 interaction | 时间窗 | 证据 |
|---|---|---|---|
| `BlocksPerFav` | 被拉黑数（`stateId ∈ {0,2}`，去重） | **30 天** | `RateBasedLabels.scala:81-85,120-140`；`BlocksPerFav.scala:12` |
| `ReportsPerFav` | `Tool.AbuseTriageTool` 举报数 | **180 天** | `RateBasedLabels.scala:65-66,86-90,142-159`；`ReportsPerFav.scala:14` |
| `SpamReportsPerFav` | `isLegit == true` 的垃圾举报 | 30 天 | `RateBasedLabels.scala:67-68,91-95,161-184`；`SpamReportsPerFav.scala:14` |
| `AllSpamReportsPerFav` | 全部垃圾举报（不过滤 `isLegit`） | 30 天 | `RateBasedLabels.scala:69-70,96-100`；`SpamReportsPerFav.scala:26` |

- **只有 `ReportsPerFav` 用 180 天长窗**，其余三个 30 天（`RateBasedLabelsExtraction.scala:11`、`spam_suspended/SpamSuspendedLabelExtraction.scala:16`、`nsfw/NSFWLabelExtraction.scala:13` 均 `historyDuration = Days(30)`；`agatha/scalding/RateBasedBuildJob.scala:23`、`SpagathaBuildJob.scala:21`）。**半年前的举报高峰今天仍在算你。**
- 垃圾举报 `TattleType` 白名单 `{DirectMessageReport, ReportAsSpam, UserReport, TweetReport}`（`:161-184`）；拉黑要求 `updatedAt` 在窗口内且两端过 `ArtificialUserFilter`（`:130-135`）；mention 过滤变体 `MentionFilteredBlocksPerFav` / `MentionFilteredReportsPerFav`（`BlocksPerFav.scala:23`、`ReportsPerFav.scala:26`）配套 10 种 report engagement types（`:208-224`）。
- 另两个标签：`SpamSuspended` 正样本 = 被封禁账号（reason ∈ {"other","spam"}、action == "suspend"、排除 note 含 `#chaq`，`agatha/scalding/util/GetSuspendedUsers.scala:14-26`）；`NSFW` 正样本来自已有用户标签 `{"NsfwHighPrecision","NsfwAvatarImage","NsfwBannerImage"}`（`nsfw/NSFWLabelExtraction.scala:16-20`）。负样本统一取 active 用户（`agatha/scalding/util/GetActiveUsers.scala:16-25`：非 deactivated / 非 suspended / `userState != 1`）。

### 4.3 反集中举报（brigading）的两道上限

| 机制 | 值 | 效果 | 证据 |
|---|---|---|---|
| `.distinct` 去重 (目标账号, 发起者) | — | **同一人对同一账号的重复举报/拉黑只计 1 次** | `RateBasedLabels.scala:120-140,142-159,161-184` |
| `getLabelSizes(maxTakePerSourceID = 100)` + `reservoirSample(100)` | **100** | 按**发起者**分组抽样：单个举报人/拉黑人/点赞者最多贡献 100 条记录 | `LabelUtil.scala:12-23` |
| `capFeatureSum(maxFeatureSum = 1000.0)` | **1000** | 估计全局先验时单账号特征和封顶 | `LabelUtil.scala:25-39` |

**一百个人各举报你一次，远比一个人举报你一百次严重**：后者被去重成 1，前者是 100 个独立发起者；但单个发起者的总贡献又被 100 截断，举报 farm 的边际收益迅速衰减。**不存在"至少 N 个赞才出判定"的门槛**——靠平滑 + 先验 + 只在 active 用户上做的分位校准替代。

### 4.4 blink 分与分位校准

`agatha/scalding/blink/BlinkScoreJobTemplate.scala:123-128`：`blinkScore = (sumM0M1 + ln(prior)) / (sumM0 + 1)`，`sumM0 / sumM1` 是 inbound / outbound 特征上的 PMI 矩和（先验 `:73-84`），本质是朴素贝叶斯式对数先验累加。随后 `PercentileCalibrator.calibrateDistinct`（`numPartitions=1000, k=12, reducers=500`）做百分位校准，**校准集只含 active 用户**（`:184-244`）。

**所以 agatha 校准分的语义是"你在活跃用户中的分位"，落在 [0,1]，0.99 就是活跃用户里最差 1%。** 另有标签泄漏排除（`:287-313`，如 `ReportsPerFav` 排除 BlockGraph 双向、FavGraph inbound、AbuseReportGraph inbound、LegitTattle/NonLegitTattle 双向）；Manhattan 导入数据集里 **NSFW 缺席**（`:315-320`）。公开的分位切点（`agatha/scalding/quantile/QuantileFeatureExport.scala:27-29,44-45`）：`defaultCutoffs = Seq(0.1, 0.01, 0.001, 0.0001)`（top 10%/1%/0.1%/0.01%）、`keepQuantiles = Set(0.9)`、特征名 `agatha.$label.$feature.$subclass.quantile_0.9_top$cutoff`。`agatha/scalding/util/FeaturesToLabels.scala:32-119` 只给"分位 → severity"机制，**具体取值不在仓库里**。

### 4.5 真正的判定阈值在 botmaker，不在 agatha

`botmaker-rules/scarecrow/bot/ProductionAgatha__FilterOutOrganicNotifications.bot:11-24`（bot 21278）：

```
AgathaSpamSuspended > 0.99 || AgathaAllSpamReportsPerFav > 0.999 || AgathaSpamReportsPerFav > 0.999
&& !IsHighPageRankUser && !IsUserGrayVerified && !AutoExpiringTempSkipList && !HasRemediationFatigueLabel
→ SetUserLabel("AGATHA_SPAM_TOP_USER", TTL = OneWeekInSecs)   # :28-33
→ SetRemediationFatigueLabel(6 天)                             # :34
```

`botmaker-rules/scarecrow/bot/AgathaSpamProduction__ApplySearchTopTweetLabel.bot:8-27`（bot 20998）：`AgathaAllSpamReportsPerFav > 0.9975 || AgathaSpamSuspended > 0.98`，同样要求 `!IsHighPageRankUser && !IsUserGrayVerified && !SkipList` → `SetTweetRtfApplyLabelWithExpirationMs("AGATHA_SPAM", TTL = 1 周)`。

分数入口 `scarecrow/legacy/StratoRegistry.scala:137-167` `GetUserHealthScores(userId, models)` → HSS。**0.99 / 0.999 / 0.9975 / 0.98 是 agatha 分在仓库里唯一可见的生产判定阈值。**

账号侧静态特征见 `agatha/scalding/data/loaders/CombinedUserDataLoader.scala:31-190`（窗口 **Days(21)**、9 个 loader，`agatha/scalding/data/ActiveUserFeaturesJob.scala:19-42`）：`email_state`、`create_week/month/year`、`created_via`、`creation_ip(/16)(/24)`、`follower_count_log / following_count_log / active_follower_count_log`（均 `ceil(ln(1+v))`）、`signup_country/region`、`push_device/push_client`、`profile_token`、`signup_category`、`is_verified`；排除 restricted / frictionless / deactivated。图特征源枚举 `agatha/hub/agatha/thrift/featureSource.thrift:3-29`（FollowGraph、FavGraph、BlockGraph、MuteGraph、AbuseReportGraph、LegitTattleGraph、NonLegitTattleNoBlocksGraph、DirectMessageGraph、CombinedUser 等）。

---

## 5. bdsm：行为序列机器人检测

### 5.1 维度与输入

`bdsm/README.md:102-103`：**256 种 action type / 8 个分类头 / 序列长度 512 / embedding 宽度 1024**（`bdsm/runtime/manhattan_arrow_adapter.py:22-25,36` 一致，dwell 裁剪到 300000 ms）。Rust 提取器输出 48 个 `action_seq` key（`bdsm/rust/abuse-v3-features/src/lib.rs:548-616`）：`action_types`（256 维 multi-hot）+ `continuous_actions`（time_delta、dwell_norm）+ 31 个离散上下文（`:571-601`，含 `product_surface`、`client_app_id`、`had_prior_render`、`device_battery`、`device_network`、`ip_hash`、`tweet_feed_position`、`is_promoted_tweet`、`country_code`、`timezone` 等）+ 6 个派生行为特征（`:602-607`）+ 3 个归类特征（`:608-610`）+ 6 个序列级统计（`:611-616`）。

模型（`bdsm/runtime/model.py:11-33,62-80,239-326`）：**时间感知 RoPE**（旋转位置编码由 action 时间戳驱动而非序号，所以"机械节奏"是原生输入）+ GQA + RMSNorm + SwiGLU + CLS 池化 + 128 维对比头；头是 3 层 MLP + GELU（`bdsm/runtime/task_heads.py:14-46`），backbone 服务时冻结。

### 5.2 派生特征：机器味的量化定义

`bdsm/rust/abuse-v3-features/src/derived.rs:19-77`（逐 action）：

| 特征 | 精确定义 |
|---|---|
| `action_burst_count` | 序列位置 ±5 窗口内、与本动作时间差 **< 1000 ms** 的动作个数（代码只比时间，不比动作类型） |
| `same_author_streak` | 连续对同一作者操作的长度 |
| `action_transition` | `(prev × n_at + cur) % 4096`，动作二元组哈希桶 |
| `engagement_without_impression` | 服务端动作（id ∈ {1..10, 61, 62, 70}）发生在该推文**从未被渲染**（render id ∈ {11,12}）之前 → 直接 API 调用 |
| `time_since_tweet_created` | snowflake 反解 `(id >> 22) + 1288834974657`，再 `ln_1p(分钟)/10` 截到 1.0 |
| `dwell_to_action_ratio` | 停留时长 / 动作间隔 |

`derived.rs:81-148`（序列级）：

```
action_entropy          = −Σ p(action) · ln p(action)
timing_regularity       = 1 / (1 + std(Δt))            # Δt 单位 ms；越接近 1 越像定时脚本
dwell_fraction          = count(dwell > 0) / n
unique_ips              = |distinct ip| / 100.0
sequence_time_span      = (t_max − t_min) 小时 / 168.0  # 以「周」为单位
target_tweet_repetition = max(单条推文被操作次数) / n
```

**`timing_regularity` 是最直白的机器人探针（间隔标准差越小越接近 1）；`engagement_without_impression` 抓的是"没看过就点赞"。** 另有 15 个序列汇总计数器（`manhattan_arrow_adapter.py:178,211-227`）：`total`、`server_pct`、`renders`、`dwells`、`avg_dwell`、`distinct_types`、`distinct_targets`、`distinct_posts`、`follows`、`replies`、`favs`、`retweets`、`clicks`、`photo`、`client_follows`；`server_pct` 高 = 绕过客户端直接打 API。

### 5.3 8 个头（`LegitimateUser` 是真正的第 8 个头）

`bdsm/runtime/heads.py:16-112`：

| index | head | selection_weight | 代表性 flywheel 标签 |
|---|---|---|---|
| 0 | `FollowBot` | 27,576 | FOLLOW_UNFOLLOW_CYCLE / PURE_FOLLOW_API_BURST / API_ONLY_BOT / GROWTH_SERVICE_BOT / FOLLOW_FARM_BOT |
| 1 | `LikeBot` | 60,320 | PURE_LIKE_API_BURST / LIKE_UNLIKE_CYCLE / STEADY_LIKE_DRIP / LIKE_FARM_BOT |
| 2 | `EngagementAmplifier` | 5,496 | LIKE_RETWEET_PAIR / FOLLOW_THEN_FAV_PIPELINE / OUTREACH_PIPELINE_BOT 等 7 个 |
| 3 | `ReplySpamBot` | 8,922 | REPLY_SPAM_NO_CONSUMPTION / REPLY_SPAM_BOT / CONVERSATION_SPAMMER |
| 4 | `TweetSpamBot` | 23,425 | TWEET_CREATE_BURST / QUOTE_TWEET_SPAMMER / CONTENT_AMPLIFIER |
| 5 | `RTBot` | 5,290 | PURE_RETWEET_API_BURST / RETWEET_UNRETWEET_CYCLE |
| 6 | `MultiActionBot` | 17,474 | SCROLL_AND_LIKE / SYNTHETIC_CONSUMER / PASSIVE_SURVEILLANCE_BOT / COORDINATED_INAUTHENTIC_BOT 等 9 个 |
| 7 | **`LegitimateUser`** | 0 | LEGITIMATE_ORGANIC_USER / INFREQUENT_LEGITIMATE_USER / POWER_USER_API_CLIENT / NEW_ACCOUNT_ONBOARDING / DEVELOPER_TESTING |

**`LegitimateUser` 不是"1 减去其他"，而是独立训练的反向头，构成二维判定的第二维。** 它的 flywheel 标签明确含 `POWER_USER_API_CLIENT` 与 `DEVELOPER_TESTING`——**用 API 的重度真人用户是被显式建模的合法类别**。完整 0–255 动作枚举在 `bdsm/runtime/action_names.json`。

### 5.4 二维判定 + 保护闸门

判定式（`bdsm/runtime/score_results_sink_focal.py:836-858`）：`enforcement_met ⟺ score[head] >= tau AND score[LegitimateUser] <= lambda`。

| 保护 | 条件 | 后果 | 证据 |
|---|---|---|---|
| 创作者保护 | `tweet_create_dominant >= 0.5`（SERVER_TWEET_CREATE 占比） | **阻止一切硬处罚** | `:836-858` |
| 取关主导 | `unfollow_cnt > follow_cnt` | 跳过 `FollowBot` | `:836-858` |
| 新号年龄闸门 | 账号年龄 < **48 小时** | 跳过 `FollowBot`；年龄取不到则静默不处罚（`enforcement_silenced_age_unknown`） | `:860-934,940-971`；默认值 `:406-411` |
| login-pack 闸门 | **1440 分钟**内被展示过登录 starter pack | 跳过 `FollowBot` | `:860-934`；默认值 `:413-421` |
| starter-pack / dwell-dropout 闸门 | `--starter-pack-gate-mode` **默认 `off`（代码存在但未启用）**；dwell 流失特征命中 | 前者 `challenge` 模式下改挑战，后者跳过处罚 | `:422-425,890-918` |
| `ReplySpamBot` 硬封禁 | 官方客户端 + 主导动作占比 ≥ **0.90** | 才允许硬封 | `:931`；默认值 `:578-586` |
| **cusp 带** | `bot >= tau − delta && legit <= lambda + delta` | **不封号，改挑战**（arkose / captcha / liveness） | `:981-995,187-205` |
| 动作数不足 | `total_actions < min_actions_for_enforcement` | 只打 `enforcement_gated_low_actions` | `:972-976` |

官方客户端 id 是**真实值**：`official_client_app_ids: [3033300, 129032, 258901, 191841]`（`bdsm/runtime/sink_policy.yaml:38`）。**所有操作点都是哨兵，不是生产值**（`sink_policy.yaml:15-40`）：

```
min_actions_for_enforcement: 999999        # 不可能的计数
thresholds:      FollowBot / EngagementAmplifier / RTBot    = [9.99, 9.99]
cusp_delta: 9.99;  cusp_heads: EngagementAmplifier          = [9.99, 9.99]
paused_liveness: LikeBot / MultiActionBot                   = [9.99, 9.99]
spam_bounce:     TweetSpamBot(create) / ReplySpamBot(reply)  = [9.99, 9.99]
reply_spam_hard_suspend_tau: 9.99
```

`sink_policy.yaml:4-13` 与 `bdsm/README.md:19-40` 明说：概率用越界哨兵 `9.99`、计数用不可能值 `999999` 替换，生产值内部配置。**结构、头名、动作映射、闸门逻辑是真的；阈值一个都不公开**——"bdsm 分超过多少会被封"在本知识库里无法回答。

### 5.5 账号侧特征在开源导出里被置零

`lib.rs:620-626` 声明 5 路账号特征 `account_age_norm`、`followers_log`、`is_verified`、**`user_cred_norm`**、`app_reputation`，但全部填 0（`lib.rs:620-626`、`manhattan_arrow_adapter.py:244-250`）。**这反过来证明生产模型确实吃 user-cred 分，只是开源版把这一路输入拔掉了**，因此不能用开源导出复现线上的账号级判定。

---

## 6. grox：LLM 内容分类

### 6.1 14 个 category、43 个 policyType

`grox/flows/ptos/state.py:11-25` 的 14 个 category：`HateOrAbuse`、`ViolentSpeech`、`ChildSafety`、`NonConsensualNudity`、`IllegalAndRegulatedBehaviors`、`Spam`、`SuicideOrSelfHarm`、`AdultContent`、`ViolentMedia`、`TerrorismOrViolentExtremism`、`CivicIntegrity`、`AgeGatingHarmfulText`、`FraudAndFinancialCrime`、`LocalLawSensitiveContent`。`state.py:28-83` 把它们展开成 **43 个 policyType**：

| category | 数量 | policyType（原文） |
|---|---|---|
| 通用 | 1 | `NoViolation` |
| ViolentMedia | 5 | `ViolentMediaGraphicMedia`、`ViolentMediaGore`、`ViolentMediaWithException`、`ViolentMediaViolentSexualConduct`、`ViolentMediaBestialityAndNecrophilia` |
| AdultContent | 2 | `AdultContentSexualHard`、`AdultContentSexualSoft` |
| IllegalAndRegulatedBehaviors | 2 | `IllegalAndRegulatedBehaviorsSexualServices`、`IllegalAndRegulatedBehaviorsIllegalDrugs` |
| HateOrAbuse | 2 | `HateOrAbuseSlursWithTarget`、`HateOrAbuseInsultsWithTarget` |
| ViolentSpeech | 6 | `ViolentSpeechMajorAndSpecificThreatWithHumanTarget`、`ViolentSpeechMajorAndNonSpecificThreatWithHumanTarget`、`ViolentSpeechMajorAndSpecificThreatWithoutHumanTarget`、`ViolentSpeechMajorAndNonSpecificThreatWithoutHumanTarget`、`ViolentSpeechMinorWithHumanTarget`、`ViolentSpeechMinorWithoutHumanTarget` |
| SuicideOrSelfHarm | 4 | `SuicideOrSelfHarmEncouraging`、`SuicideOrSelfHarmDepiction`、`SuicideOrSelfHarmEngaging`、`SuicideOrSelfHarmExpressingDesire` |
| ChildSafety | 2 | `ChildSafetySexualAbuseMaterial`、`ChildSafetySexualExploitation` |
| AgeGatingHarmfulText | 5 | `AgeGatingHarmfulTextAdultContent`、`AgeGatingHarmfulTextEatingDisorder`、`AgeGatingHarmfulTextHarmfulSubstance`、`AgeGatingHarmfulTextDangerousStunt`、`AgeGatingHarmfulTextGraphicDescription` |
| **Spam** | **14** | `SpamEngagementFarming`、`SpamEngagementTrading`、`SpamFinancialScam`、`SpamHashTagAbuse`、`SpamScamLinks`、`SpamBotProduced`、`SpamPlatformManipulation`、`SpamEngagementBaiting`、`SpamPromotesClicks`、`SpamPromotesReplies`、`SpamPromotesShares`、`SpamCardManipulation`、`SpamMentionAbuse`、`SpamManipulatedMedia` |

`NonConsensualNudity`、`TerrorismOrViolentExtremism`、`CivicIntegrity`、`FraudAndFinancialCrime`、`LocalLawSensitiveContent` 五个 category 在枚举里存在，但没有对应的 policyType 分支。

### 6.2 没有数值 cutoff，公开的都是路由阈值

`state.py:86-101`：`SafetyPolicy{policyType, confidenceScore: int|None, reason}`、`SafetyPtosViolatedPolicy{category, score: int|None, reason, safetyPolicy}`。`score` / `confidenceScore` 是 **LLM 自己吐出的整数**，**sink 只按 `policyType` 分支，从不比较它们的大小**。**"grox 置信度多少会被判违规"在代码层面没有答案。** 提示词 `.j2` 未公开（`grox/flows/ptos/prompts.py:11-69` 给出理由：降低可被 game 的风险，并列出 11 个模板名），每个 policyType 的判定尺度同样不可知。

公开的数值全是**路由 / 升级**阈值（`grox/flows/ptos/constants.py:22-47`）：

| 常量 | 值 | 作用 |
|---|---|---|
| `GEMMA` | `"oai-gemma4-26b"` | 小模型 slug |
| `HIGH_FAV_THRESHOLD` | **128** | 赞数 ≥ 128 且 deluxe → 升级 Grok 4.3 |
| （硬编码） | **1024** | 赞数 ≥ 1024 → 升级 4.6-internal |
| `ADULT_CONTENT_LEADING_FRAMES_UNCONDITIONAL_FAV` | 512 | 无条件抽视频前 10 秒（视频需 ≥ 30 秒） |
| `MEDIA_INJECTED_REASONING_FAV` | 512 | 注入媒体推理 |
| `KEY_FRAMES_UNCONDITIONAL_FAV` | 1024 | 无条件关键帧 |
| `MANY_MEDIA_CHUNK_SIZE` / `MANY_MEDIA_UNCONDITIONAL_FAV` | 4 / 256 | 多图分块 |

证据：`grox/flows/ptos/classifier.py:627-648`（升级分支）、`:577-607`（SUPPORTED / DELUXE_4_3 / USE_REASONING / USE_GEMMA / USE_THREAD 类别集合）、`:70-102`（熔断器）、`:198-404`（**跨模型交叉验证：两模型不一致 → 降为 `NoViolation`，或降级为 `ViolentMediaGraphicMedia`**）。

**结论：内容越火，审得越狠、用的模型越贵。** 这是"推流量"与"风控强度"直接耦合的证据——爆帖并不比冷帖更安全，反而会被更贵的模型反复复核。另：`task_safety_ptos_policy.py:76-86,130-174` 已有 NSFW 前科强制走 `AdultContentSexualHard`、高赞成人复检合成 `score=50`；`task_safety_ptos_safemodel_sex_nudity.py:22-33,79-89,123-153` 专用 slug `sex-and-nudity`、**正例桶 = {"R","X"}**、每视频 8 帧、每帖最多 12 个 payload、异常直接丢弃判定；`prior_nsfw.py:32-34` 读 `safetyBoolMetadata.isNsfw`。embedding 流水线另有算力闸门 `grox/flows/mm_emb/adaptive_min_fav.py:7-19,54-63`：`AdaptiveMinFav(start=20_000, target_qps=5.0, gain=0.3, deadband=0.1, window_s=30.0, floor=0, cap=20_000, warmup_s=60.0)`，**闲时门槛降到 0（全都算），忙时抬到 2 万赞**。

### 6.4 回复垃圾：独立的 0–3 分链路

- `grox/flows/reply_spam/classifier_reply_ranking.py:164-170`：score 必须落在 **[0,3]** rubric，越界抛错；`:48-51` 直方图桶 `[0.0, 1.0, 2.0, 3.0]`。
- `grox/flows/reply_spam/task_write.py:140-141`：**`score == 0.0` → 打 `RiskyHighVizReply`**；`:127-138` 只在新分更低时才覆盖旧分（**单调下降，回复分只会越来越差**）。
- 路由阈值（`grox/flows/reply_spam/constants.py:5-9`）：`GEMMA_REPLY_SPAM_MIN_FOLLOWERS = 125_000`、`GROK_GEMMA_FOLLOWER_SPLIT = 250_000`、`RISKY_HIGH_VIZ_REPLY_EXEMPT_MIN_PAGE_RANK_SCORE = ` **66**。豁免用法 `task_write.py:39-45`：**有分数比 66，无分数退回 `isHighPageRankUser`**。
- `task_filter.py:78-93` 被回复者或根帖作者粉丝 > 250,000 → 跳过 spam detection 走 reply_ranking；`:98,158-163` coordinated spam 要求根帖作者粉丝 ≥ **180,000**（代码里的 "blast radius"）；`:164-180` 高 page-rank / 灰标直接跳过。
- botmaker 侧同名标签：`botmaker-rules/scarecrow/bot/GroxTweetProcessor.bot`（bot 25026）`spamScore >= 0.97` → `RISKY_HIGH_VIZ_REPLY`，TTL **14 天**，跳过"会话作者自己的回复"与高权重/灰标/skiplist。

**`RiskyHighVizReply` 只掐通知，不掐 For You**——见 §8.4。

---

## 7. 媒体模型与"校准曲线取点"

约定 `MMP = media-model-proxy/src/main/scala/com/twitter/media_understanding/model_proxy/model_descriptors/`。

### 7.1 只注册了 7 个模型

`MMP/ModelDescriptorRegistry.scala:9-19`：

| MediaModel | 服务路径 / 超时 | 输出标签 | 证据 |
|---|---|---|---|
| `XxNsfw` | `/s/xx-nsfw/xx-nsfw`，8000 ms | `nsfw.default.probability` / `.score` / `.precision` / `.recall` / `.fpr` | `MMP/XXNsfwModelDescriptor.scala:36-44,76-85` |
| `Fingerprinting` | `/s/magicpony-fingerprinting/magicpony-fingerprinting`，3000 ms | `pixel_variance`、`embedding`（Tensor FLOAT） | `MMP/FingerprintingModelDescriptor.scala:30-35,63-65` |
| `FingerprintingV2` | 同上，3000 ms | 同上 | `MMP/FingerprintingV2ModelDescriptor.scala:30-35,63-65` |
| `ViolenceAndGore` | `/s/violence-and-gore/violence-and-gore`，3000 ms | **未公开** | `MMP/ViolenceAndGoreModelDescriptor.scala:64-69` |
| `HatefulSymbolRecognition` | `/s/magicpony-hateful/magicpony-hateful-symbol-recognition`，3000 ms | **未公开** | `MMP/HatefulSymbolRecognitionModelDescriptor.scala:45-47` |
| `CategoryClassification` | `/s/magicpony-category/magicpony-category-classification`，3000 ms | **未公开** | `MMP/CategoryClassificationModelDescriptor.scala:50-52` |
| `CategoryClassificationEmbeddings` | `/s/embeddings-category/embeddings-category-classification`，4000 ms | **未公开**，`dimensions = 256` | `MMP/CategoryClassificationEmbeddingsModelDescriptor.scala:52-60` |

`XxNsfw` 支持 `{TweetImage, TweetVideo, PeriscopeVideo, TweetGif}`（`XXNsfwModelDescriptor.scala:29-34`）；`ViolenceAndGore` 额外含 `{AvatarImage, BannerImage}`（`ViolenceAndGoreModelDescriptor.scala:35-41`）——**头像和横幅也过暴力模型**。Thrift 枚举 20 位（`media-model-proxy/src/main/thrift/com/twitter/cortex_media_annotator/annotate.thrift:8-29`），`XX_NSFW_V2` 已定义但**未注册**、`RESERVED_9..20` 占位 → **生产模型数量多于开源的 7 个**。标签名缺失原因已定位：基类 `def labels(): Map[String, Long] = Map()` 默认空（`MMP/ModelDescriptor.scala:25`），那 4 个模型没有 override。

缺失的 `ViolenceAndGore` 阈值可从消费侧反推（`botmaker-rules/scarecrow/bot/ViolenceAndGore_ImageModel_MTT.bot:10-19,33-42`）：`TWEET_IMAGE` precision > **0.6**；`TWEET_VIDEO` raw score ≥ **0.95**；`AVATAR_IMAGE` / `BANNER_IMAGE` raw score ≥ **0.85**。`:88-101` `!IsHighPageRankUser` → `TweetRtfApplyLabel("GORE_AND_VIOLENCE_HIGH_PRECISION")`，否则**转人工**。

### 7.2 clip：256 维图文共享空间

`clip/config.py:6,11-25`：`DEFAULT_FINAL_EMBEDDING_DIM = 256`、`input_resolution=224`、`clip_model_type="ViT-B/32"`、`logit_scale=4.5065`、`batch_size=128`、`learning_rate=2e-5`、`num_training_steps=100000`、`num_warmup_steps=500`。生产模型 `clip/keras_model.py:13-14` `PROD_MODEL = TWITTER_MODELS[0]` = **`Twitter-ViT-B/32-256`**（另有 128 维版未上线），两个变体都以开源 `ViT-B/32` 为底座继续训练（`clip/model.py:45-52`）；输出 **L2 归一化**（`clip/keras_model.py:128-130,138-140`）。编码器之上加 `PositionwiseFeedForward`（`clip/modules.py:31-41,44-81`），双向 `CrossEntropyLoss` 对比训练（`clip/training.py:143,163-171`）+ AdamW(betas=(0.9,0.98), eps=1e-6, weight_decay=0.01)（`clip/utils/train_utils.py:29-39`），数据是 `{tweet_text, image_byte_string}` 配对（`clip/datasets/language_image_dataset.py:29-32`）。

**文本预处理会删掉 URL**：`clip/utils/data_utils.py:44-53` `regex_replace(text, r"\n|\t|\r|\r\n|http\S+", "")`。**embedding 里的文本语义不含链接**，链接风险由独立的 URL 模型负责。图像归一化用 Twitter 自己的均值方差（`data_utils.py:17-18`），与导出脚本不一致（§9.3）。

### 7.3 adult-content 输出的不是布尔值，而是一整条曲线

`adult-content/config.py:6,16-20,36`：embedding 256、Dense 128、batch 256、lr 0.001、100 epochs、400 steps、`num_thresholds=200`；网络 BatchNorm → Dense(128, gelu) → Dense(1, sigmoid)（`adult-content/training.py:25-38`），指标 `PrecisionAtRecall(0.9)` + PR-AUC、EarlyStopping patience 5（`:66-76`），50/50 拒绝重采样（`adult-content/dataset_utils.py:10-12,15-23`）。校准（`adult-content/calibration.py`）：

| 步骤 | 内容 | 行号 |
|---|---|---|
| 阈值网格 | `np.linspace(0, 1, 200)` | `:16-20` |
| 逐阈值指标 | precision / recall / fpr（分母为 0 时取 1） | `:22-32` |
| 桶内正例率 | `pos_count / total`（空桶取上界） | `:38-46` |
| **保序回归** | `IsotonicRegression(y_min=0, y_max=1, increasing=True, out_of_bounds="clip")` | `:61-69` |
| 输出 | `thresholds_adult / precision_at_thresholds_adult / recall_at_thresholds_adult / false_positive_rate_at_thresholds_adult / probability_at_thresholds_adult` → `metrics_at_thresholds.csv` | `:78-88,97` |

**模型交付的是 (threshold, precision, recall, fpr) 整条曲线，"是不是色情"由运营在曲线上选哪个点决定。** 生产操作点在 `botmaker-rules/scarecrow/derived-feature/`：

| 派生特征 | 取点方式 | 值 |
|---|---|---|
| `IsHighPrecisionNsfwNewModelLogic.df:3-4` | `precisionNewNsfw >=` | **0.95** |
| `IsNearPerfectNsfwNewModelLogic.df:3-4` | `precisionNewNsfw >=` | **0.999** |
| `IsHighRecallNsfwNewModelLogic.df:3-9` | `recallNewNsfw <=`，非视频 | **0.8568428** |
| 同上 | `recallNewNsfw <=`，`category == "TWEET_VIDEO"` | **0.6** |

方向相反：HighPrecision 用 `precision ≥`，HighRecall 用 `recall ≤`（沿曲线往高召回方向走）。**视频的高召回门槛（0.6）比图片（0.857）宽松得多，即视频更容易被召回打标。**

### 7.4 pnsfwmedia：同一张图，发在不同账号上得分不同

融合方式是**早期拼接 MLP**，不是规则加权。`pnsfwmedia/model_experimental.py:50-92` `_get_final_feature_tensor` 把 **8 路特征 concatenate**：

| # | 特征（原文） | 说明 |
|---|---|---|
| 1 | `image_score` | 冻结 CLIP 作用于 `media.mediaunderstanding.media_embeddings.twitter_clip_as_tensor`（256 维，`:51-53,126-128`） |
| 2 | `source_user.hss.user_health_scores.agatha_calibrated_nsfw_score` | **账号的 agatha 校准 NSFW 分** |
| 3 | `source_user.hss.user_health_scores.nsfw_text_user_score` | 账号文本 NSFW 分 |
| 4 | `ln(followed_by_count + 10.0)` | 粉丝数对数（`:63-69`，+10 平滑） |
| 5 | `source_user.hss.user_health_scores.nsfw_consumer_follower_score` | **"你的粉丝里有多少是色情内容消费者"** |
| 6–8 | 上述 2/3/5 的 `== -1.0` 缺失指示位 | `:71-79` |

网络：CLIP `trainable=False` → `BatchNormalization` → `Dense(50, relu)` → `Dense(1, sigmoid)`（`:22-26,44-48`），缺失默认值 −1.0（`:108-133`）。**这是"账号信誉直接参与内容判定"的最直接实现：第 2 路是账号历史举报/封禁分位，第 5 路是受众画像；同图不同号、粉丝构成不同，输出就不同。** `pnsfwmedia` / `adult-content` 的 Python 里**没有任何决策阈值**，阈值全在 §7.3 的 `.df` 里。

### 7.5 soft-nsfw 与 hard-nsfw：后果不同

`grox/flows/ptos/task_write_safety_post_annotations_result_sink.py:214-231`：`AdultContentSexualHard` → `NsfwHighRecall`（含媒体再追加 `NsfwHighPrecision`）；`AdultContentSexualSoft` → `SoftNsfw`。下游（`visibility-filtering/rules/tweet_rules.rs`）：

| 标签 | 规则 | 效果 |
|---|---|---|
| `NSFW_HIGH_RECALL` | `:912-917` | 对非作者无条件 `drop_post(ContainNsfwMedia)` |
| `NSFW_HIGH_PRECISION` | `:457-585` | 一大族规则，按观众设置/年龄/国家分别 blur / interstitial / tombstone / drop |
| `SOFT_NSFW` | `:919-928` | **只在 `RequestHasSoftNsfwNewUserDrop && ViewerIsNewAccount` 时**对非作者 drop |

**hard 对所有人生效，soft 只对新账号观众生效。** 且 `:204-231` 这段**没有 page-rank 豁免**——色情与暴力不认账号权重，只有 Spam / 违法 / 辱骂 / 自残 / 儿童安全才认（§8.2）。在 For You 层成人/血腥内容是**被 Drop 而不是被 blur**：blur 规则被更早的 Drop 抢占，模糊只发生在 Hydration（渲染）层。用户级标签传播见 `botmaker-rules/scarecrow/bot/NsfwTweetMediaProcessor.bot:7-29`（bot 22418）：`label=="3" && score>0.99` → `NSFW_NEAR_PERFECT`；`label=="3"` → `NSFW_HIGH_PRECISION`；`label=="4"` → `NSFW_HIGH_RECALL`。

---

## 8. 完整闭环：分数 → 豁免 → 标签 → 丢弃

### 8.1 分数落地与唯一的数值闸门

`user-cred-v2/UserCredV2App.scala:453-506` 写 Manhattan → `scarecrow/legacy/StratoRegistry.scala:120-135` `GetUserCredV2(userId).score`（下游常量 `scarecrow/legacy/DownstreamServices.scala:51-53`）。`botmaker-rules/scarecrow/derived-feature/HighPageRankThreshold.df:2` = **54**；`IsHighPageRankUser.df:4-18`：

```
:userCredScore            = GetUserCredV2(:userId).score
:predictedHighPageRank    = Contains(:userLabels, "PREDICTED_HIGH_PAGE_RANK")
:pageRankCriteria         = Coalesce(:userCredScore, -1) >= 54 || :predictedHighPageRank
:fallbackFollowerCountCriteria = :followerCountFromGizmoduck > 25000
:usePageRankCriteria      = :userCredScore != NULL || :predictedHighPageRank
:isHighPageRankUser       = if (:usePageRankCriteria) :pageRankCriteria else :fallbackFollowerCountCriteria
```

**取不到分数时退化为"粉丝 > 25000"。** 第二个数值闸门是回复链路的 **66**（`grox/flows/reply_spam/constants.py:9`，用法 `task_write.py:39-45`）。

### 8.2 豁免散布在 grox sink + ~12 个 bot

grox PTOS sink `:189-193`：`is_high_page_rank_user = is_high_page_rank_v2_user(author) or is_grey_badge_user(author)`（loader `grox/core/data_loaders/strato_loader.py:60-84`）。

| 分支 | 行号 | 是否认权重 |
|---|---|---|
| Spam 默认分支 | `:250` | `should_label_for_spam = not is_high_page_rank_user` |
| `SpamEngagementBaiting` / `SpamEngagementFarming` / `SpamCardManipulation` / `SpamPromotesShares` | `:236-248` | **无豁免，永远打 `SpamHighRecall`** |
| `NoViolation` / `SpamPromotesClicks` / `SpamPromotesReplies` | `:236-248,264-279` | **永远不打 Spam 标**，后两者只打 `PromotesClicks` / `PromotesReplies` |
| 违法与受管制行为 | `:281-287` | 仅非高权重打 `SpamHighRecall` |
| `HateOrAbuseInsultsWithTarget` **且 `post.language == "en"`** | `:289-299` | 非高权重 → `FosnrAbuseInsults`（**英语辱骂才管**） |
| 自残鼓励 / 描绘 | `:301-315` | 非高权重 → bounce post |
| 儿童性剥削 | `:328-338` | 非高权重 → suspend user |
| ViolentMedia / AdultContent | `:204-231` | **无豁免** |

botmaker 侧 `!IsHighPageRankUser` 门控（行号）：`Tweet_Search_Blacklist_RTF_All_UNSAFE_URL_Sources.bot:18`、`Tweet_Spam_High_Recall_RTF_All_Bad_URL_Sources.bot:21`、`LQ_Tweets_With_LQ_URL_Verdict_At_Mention_To_NonFollower.bot:29` 与 `_v2.bot:11`、`BBQDuplicateTextProd.bot:31`、`BBQDuplicateTextRepliesProd.bot:30`、`ProductionAgatha__FilterOutOrganicNotifications.bot:22`、`FollowFromActorWithPinnedLowQualityOrBadUrl.bot:31`、`AgathaSpamProduction__ApplySearchTopTweetLabel.bot:16`、`PinnedLowQualityOrBadUrl.bot:27`、`GroxTweetProcessor.bot:17`。

NSFW 用户标签的特殊优待（`botmaker-rules/scarecrow/derived-feature/ApplyNsfwUserLabelOrCreateReport.df:5-82`）：高权重 / 灰标 / 金标 / skiplist → **转人工审核而非直接打标**；即使打标 **TTL 仅 3 天**（`OneDayInSecs*3`）而默认 7 天；举报限流 **1 次/周**；**90 天**人工移除记忆；额外守卫 `IsHighPageRankUser && NsfwConsumerFollowerScoreDouble < 0.1`（判为疑似误报）。

### 8.3 帖子标签聚合成账号标签

`safety-label-user-agg/safetyLabelToUserLevelAggregationV2Processor.strato:31-58` 取 `platform-manipulation/isHighPageRankV2` 与 `isGreyBadge` 组成 `userContext.highPageRankOrGreyBadge`，`eligibleRules = triggeredRules.filter { !isExcluded(rule, userContext) }`；`:89-106` 经 `gizmoduckSetUserLabelsColumn.put(userId, labels)` 写入，`byUser = "Grox"`。`safety-label-user-agg/postToUserLabelRules.strato:360-428` 两条默认生产规则：

| rule | 触发帖子标签 | windowSize | minimumMatchingPosts | maxPostAgeDays | 产出用户标签 | TTL | 排除高权重 |
|---|---|---|---|---|---|---|---|
| `possibly_nsfw_account` | NSFW_HIGH_PRECISION / SOFT_NSFW | 10 | **11** | 60 | POSSIBLY_NSFW_ACCOUNT | 7 天 | **true** |
| `nsfw_high_precision` | NSFW_HIGH_PRECISION | **5** | **3** | 60 | NSFW_HIGH_PRECISION | 7 天 | false |

**`possibly_nsfw_account` 在默认配置下永远不可能触发**：计数逻辑是 `.take(windowSize).size >= minimumMatchingPosts`（`:266-284`），10 里取 11 不可满足（`:373-375`；校验上限 `:96-107` 允许 windowSize ≤ 10、minimumMatchingPosts ≤ 11、maxPostAgeDays ≤ 60、ttl ≤ 7、mediaOnlyScanMultiplier 4）。**实际生效的只有 `nsfw_high_precision`：60 天内最近 5 条帖里有 3 条被判 NSFW_HIGH_PRECISION → 整个账号被打上 NSFW_HIGH_PRECISION，为期 7 天，且不豁免高权重。** 这是处罚从单帖扩散到全号的唯一默认路径。

### 8.4 账号标签 → 直接丢弃，以及"限流"的精确语义

`visibility-filtering/models/author.rs:20-37` `AuthorLabel` 枚举 16 个，字符串映射 `visibility-filtering/hydration/decode/author.rs:199-207`。`visibility-filtering/rules/author_rules.rs` 里**每条都是 `drop_post`**：

| 行号 | AuthorLabel | audience | 装配面 |
|---|---|---|---|
| `:169-174` | NsfwHighRecall | NonAuthors | For You |
| `:176-181` | NsfwHighPrecision | NonAuthors | For You |
| `:183-195` | NsfwAvatarImage / NsfwBannerImage | NonAuthors | For You |
| `:197-202` | NsfwNearPerfect | NonAuthors | For You |
| `:204-209` | SpamHighRecall | NonAuthors | For You + 通知 |
| `:211-223` | Compromised / ReadOnly | NonAuthors | For You + 通知 |
| `:225-230` | ImpersonationHighPrecision | NonAuthors | For You + 通知 |
| `:232-237` | AbusiveHighRecall | **NonFollowers** | For You + 通知 |
| `:239-244` | DoNotAmplify | **NonFollowers** | For You |
| `:246-251` | NotGraduated | **NonFollowers** | **仅通知** |
| `:253-258` | **AgathaSpamTopUser** | **NonFollowers** | **仅通知** |
| `:260-265` | EngagementSpammer | **NonFollowers** | **仅通知** |
| `:267-276` | **BlinkWorst**（+ `ViewerHasUqfEnabled` + `!ViewerHasBlinkLabel`） | **NonFollowers** | **仅通知** |
| `:278-283` | DownrankSpamReply | **NonFollowers** | **仅通知** |

audience 不可混淆：**`NonAuthors` = 除作者本人以外全部丢弃（含粉丝）；`NonFollowers` = 作者与粉丝照常可见，只丢弃陌生人。** 装配证据（`visibility-filtering/rules/levels.rs`）：

- `TIMELINE_HOME_RECOMMENDATIONS`（`:338-352`）user 段 = 账号状态 + block/mute + **7 条 NSFW 相关账号规则**（含 5 条 AuthorLabel 规则）+ `OON_AUTHOR_LABEL_DROPS`（`:101-108`：SpamHighRecall / Compromised / ReadOnly / ImpersonationHighPrecision / AbusiveHighRecall / DoNotAmplify）。帖子段（`:353-380`）另含 `SPAM_DROP_UNDESIRABLE`、`FOSNR_DROPS`、`AGE_GATING_DROPS`、`HOME_BLURS`、`OON_POST_DROPS`（`:215-220`：DoNotAmplify / MaliciousUrl / SpamHighRecall / BrazilElectionLegal）、`FOSNR_ABUSE_INSULTS_DROP_UNDESIRABLE`。
- `TIMELINE_HOME`（关注流，`:318-336`）user 段**只有账号状态和 block/mute，没有任何信誉标签规则**。
- SafetyLevel 编号（`visibility-filtering/rules/safety_level.rs:23-33,384-401`）：`TimelineHome=8`、`FilterAll=16`、**`TimelineHomeRecommendations=61`**、`TimelineHomeHydration=82`、`TimelineHomePromotedHydration=124`、`NotificationsFollow=246`、`NotificationsWriterV2=72`。

**"限流"的准确含义：`audience: NonFollowers` / `NonAuthors` 的 `drop_post` 只挂在 `TIMELINE_HOME_RECOMMENDATIONS`（level 61）上，关注流（level 8）不受影响。它不是降权系数，而是推荐资格的布尔剥夺——要么进推荐池，要么不进。**

**一条必须纠正的常见误解**：`BLINK_WORST` / `AGATHA_SPAM_TOP_USER` / `ENGAGEMENT_SPAMMER` / `NOT_GRADUATED` / `DOWNRANK_SPAM_REPLY` 只装在 `NOTIFICATION_AUTHOR_LABEL_DROPS`（`levels.rs:132-143`），作用于 `NOTIFICATIONS_FOLLOW`、`NOTIFICATIONS_WRITER_V2_*`。**agatha 最差分位的账号主要被掐通知触达，而不是被掐时间线。** 帖子级同理：`RISKY_HIGH_VIZ_REPLY_OON_DROP_UNSPECIFIED`（`tweet_rules.rs:1029-1034`）只装在 `levels.rs:259`（`NOTIFICATIONS_WRITER_V2_MENTION`）与 `:275`（`NOTIFICATIONS_WRITER_V2_MEDIA_TAGGED`）；`SPAM_HIGH_RECALL_OON_DROP_UNDESIRABLE`（`:1022-1027`）只装在 `levels.rs:274`；`NOTIFICATIONS_WRITER_V2_REPLY = NOTIFICATIONS_WRITER_V2_MENTION`（`:262`）；`LOW_QUALITY_AND_UQF_DROPS`（含 `DOWNRANK_SPAM_REPLY_UQF_DROP_UNSPECIFIED`）与 `COMMUNITY_AND_SPAM_DROPS` 只在 `levels.rs:253,258,292,297`。

**所以 grox 的 `RiskyHighVizReply` 让"被你回复的人收不到这条回复的通知"，它不会把回复从 For You 里删掉。** 真正影响 For You 的是**另一个**帖子规则 `SPAM_HIGH_RECALL_DROP_UNDESIRABLE`（`tweet_rules.rs:944-949`，audience `NonAuthors`），它经 `OON_POST_DROPS` 装进 level 61。

### 8.5 处罚服务里的信誉前置豁免与标签映射

`abuse-enforcement-service/service-lib/src/strato.rs:134-142` `compose_cred`：`is_high = is_grey_badge || is_high_page_rank_user`，同时带上 `score` 与 `follower_count`（结构体 `src/entities.rs:10-15`）。`abuse-enforcement-service/service-lib/rules/enforcement_user.yaml:19-33` 两条 skip **排在所有处罚规则之前**：`high_follower_count`（`cred.follower_count >= 12.34`）与 `pagerank_skipped`（`cred.is_high || cred.score >= 12.34`）。**`12.34` / `12345.67` 是 YAML 注释明说的 mock 值（`:20,26`；帖子侧 `enforcement_post.yaml:24,30`），生产阈值不公开。** 帖子侧同样两条但多了 `&& !score.skip_author_credibility_prechecks`（`enforcement_post.yaml:23-37`）——**某些模型可以强制绕过信誉豁免**。

`enforcement_user.yaml:36-189` 的标签 → 动作映射：

| score.labels | 动作 | TTL |
|---|---|---|
| `anchor_campaign_suspend` / `panda_reports_embedding_v10_rough_spam` / `bb1_post_spam_bot_suspend` / `bb1_reply_spam_bot_suspend` / `bb1_user_suspend` | `act_suspend_user`（perm=false, PlatformManipulation） | — |
| `anchor_campaign_suspend_cse` | `act_suspend_user`（**perm=true**, Cse） | — |
| `bb1_post_spam_bot_bounce` / `bb1_reply_spam_bot_bounce` / `bb1_user_bounce` | SpamHighRecall + `act_spam_liveness_check` | **2592000000 ms = 30 天** |
| `liveness_check_and_spam_high_recall_7d` / `spam_high_recall_7d` / `llm_slop_user` | SpamHighRecall（前者 + liveness） | **604800000 ms = 7 天** |
| `SpamEmbeddingMajorityPoster` | SpamHighRecall | 30 天 |
| `enforcement_cusp_arkose` / `_captcha` / `_liveness`（且无 `enforcement_threshold_reached`） | arkose / captcha / liveness | — |
| 兜底 `when: "true"` | `act_suspend_user` | — |

帖子侧（`enforcement_post.yaml:39-76`）：`llm_slop_post` → **RiskyHighVizReply**（30 天）；`gibberish_post` / `fast_reply_spam_post` / `anchor_campaign_post` / `SpamEmbeddingPtosDistilled` → **SpamHighRecall**（30 天）；`cse_reports_embedding_v2` → 永久封号（Cse）；兜底 `post_no_actionable_label` 是 skip 而非处罚。

**闭环完成**：`bb1_*`（bdsm）→ `SpamHighRecall` 用户/帖子标签 → `author_rules.rs:204-209` / `tweet_rules.rs:944-949` → **For You 对非作者丢弃**；而 `llm_slop_post` → `RiskyHighVizReply` → **只掐通知**。

---

## 9. 未公开 / 不存在 / 内部矛盾（诚实清单）

类型：`删减` = 官方主动移除；`不存在` = 设计上就没有；`矛盾` = 开源导出瑕疵，回答时应主动声明。

| # | 类型 | 内容 | 证据 |
|---|---|---|---|
| 1 | 删减 | grox 全部 LLM 提示词 `.j2`（11 个模板名可见、内容不可见）→ 每个 policyType 的判定尺度不可知 | `grox/flows/ptos/prompts.py:11-69` |
| 2 | 删减 | bdsm 全部操作点：`[tau, lambda]`、`cusp_delta`、`reply_spam_hard_suspend_tau`、`min_actions_for_enforcement` 用 `9.99` / `999999` 哨兵替换 | `bdsm/runtime/sink_policy.yaml:4-13`；`bdsm/README.md:19-40` |
| 3 | 删减 | 处罚服务的信誉/粉丝豁免门槛：`12.34` / `12345.67` 是 mock，注释明说 "Prod uses a different threshold ... to reduce gaming" | `enforcement_user.yaml:20,26`；`enforcement_post.yaml:24,30` |
| 4 | 删减 | bdsm 的 5 路 `user_features`（含 `user_cred_norm`）在开源导出中全置 0 | `lib.rs:620-626`；`manhattan_arrow_adapter.py:244-250` |
| 5 | 删减 | media-model-proxy 中 4 个模型的输出标签名（基类默认空，未 override） | `MMP/ModelDescriptor.scala:25` |
| 6 | 删减 | agatha 分位 → severity 的具体取值；生产还 union 了第三个未公开人群 | `FeaturesToLabels.scala:32-119`；`ActiveUserFeaturesJob.scala:19-42` |
| 7 | 删减 | clip 预训练权重 URL 全部替换为 `https://example.invalid/...` | `clip/model.py:36-46` |
| 8 | 不存在 | user-cred-v2 的**分档 / tier 表**：只有连续 score 与两条健康度统计线（55 / 90） | `SnapshotSafeguard.scala:21-89` |
| 9 | 不存在 | user-cred-v2 的**边权重**：结构体只有两个 id | `Edge.scala:11-19` |
| 10 | 不存在 | agatha 的**"至少 N 个赞才判定"门槛**：靠平滑 + 先验 + 分位校准 | `RateBasedLabels.scala:44-56` |
| 11 | 不存在 | grox PTOS sink 对 LLM `score` / `confidenceScore` 的**数值比较**：只按 policyType 分支 | `state.py:86-101` + sink |
| 12 | 不存在 | `pnsfwmedia` / `adult-content` Python 里的**决策阈值**：只有校准曲线，阈值在 `.df` 里 | 见 §7.3 |
| 13 | 矛盾 | `client_app_id → platform` 两套映射不一致：Rust 为 `258901→1, 3033300→2, 0<id<1000→4, else 0`；Python 训练方言为 `258901→1, 129032→2, 3033300→3, 0<id<1000→4`。且 Rust 的 `action_name_to_group` 漏了 `feature_norm.py` 分配的若干 id（60、39、67、64、65、66 及 group 12） | `bdsm/rust/abuse-v3-features/src/lib.rs:188-195` vs `bdsm/runtime/feature_norm.py:52-61` |
| 14 | 矛盾 | `possibly_nsfw_account` 默认 `windowSize: 10` 但 `minimumMatchingPosts: 11` → **默认配置永不触发** | `postToUserLabelRules.strato:373-375` vs `:266-284` |
| 15 | 矛盾 | clip 导出脚本用 `PRETRAINED_MEANS/STDEVS`，训练/验证预处理默认用 `TWITTER_MEANS/STDEVS` → 归一化常数不一致 | `clip/scripts/export_dbv2_image_model.py:34-35` vs `clip/utils/data_utils.py:59-60,87-88` |

**因此：54 / 66 是 botmaker 与 grox 侧的真值；处罚服务侧的真值未知；bdsm 侧一个阈值都不公开。**

---

## 10. 三句话结论

1. **账号权重 = 一个对数 PageRank 分**（`clamp(165.2 + 7.07·ln(mass), 0, 100)`）：种子集一半是认证账号，互动边只算赞和转推、只看 7 天、关联小号之间的边被删掉。它**不直接降权**，只决定你在 **54**（回复场景 **66**）之上还是之下——线上享受"转人工 / 短 TTL / 直接豁免"，线下被模型判定原样执行。
2. **内容判定是多模型并联 + 校准曲线取点**：色情模型交付整条 (threshold, precision, recall, fpr) 曲线，运营取 precision ≥ 0.95 / ≥ 0.999、recall ≤ 0.857（视频 ≤ 0.6）三种严格度；pnsfwmedia 把**账号 agatha 校准分、粉丝数对数、粉丝里的色情消费者比例**直接拼进图像分类器输入——**同图不同号，结果不同**。
3. **"限流"= 对非粉丝/非作者隐藏，且只发生在推荐层**（level 61；关注流 level 8 的 user 段没有信誉标签规则），是**推荐资格的布尔剥夺**而非分数乘子；账号级标签（60 天内 5 条帖中 3 条 NSFW → 账号 NSFW_HIGH_PRECISION，7 天）让处罚从单帖扩散到全号。agatha / grox 回复链路派生的那批标签掐的是**通知**，不是时间线。