# 08 · 运营结论与自查：代码支持什么，不支持什么

> 本篇是前七篇的综合。所有结论标注三档：
> **【实证】** = 有生产默认值 + `文件:行号`；**【推测】** = 机制上合理但代码未直接支持；**【不公开】** = 上游刻意未放出。
> 证据基准 commit `a284320b66a9dce35e6f5d6b052ee308eeb12326`。

---

## 1. 先分清四种「没曝光」——诊断方式完全不同

这是本篇最重要的一节。绝大多数「我被限流了」的判断错在**把四种不同的故障当成一种**。

| # | 故障 | 发生位置 | 表现 | 能否自查 |
|---|---|---|---|---|
| A | **没进召回索引** | `phoenix-rankall-strato`（离线，发帖时） | 帖子在个人主页正常，但 For You 里从来不出现，连关注你的人也刷不到 | 间接 |
| B | **进了索引，被在线 VF 判 DROP** | `home-mixer/filters/vf_filter.rs`（排序后） | 分数可能很高、排到第 3 位，然后消失 | Under the Hood 能看到标签 |
| C | **进了也展示了，但排得低 / 被去重** | 打分 + `DedupConversationFilter` | 有曝光但量少；或 thread 里只有一条出现 | 看曝光数与互动率 |
| D | **只是通知被掐** | `visibility-filtering/rules/levels.rs:253-297` | 对方没收到你回复的通知，但回复本身在 For You 里正常 | 难 |

**A 和 B 是可见性问题，C 是排序问题，D 根本不是曝光问题。** 两套独立系统（见 `01-architecture` §1）。

### 1.1 D 类最容易被误判成限流

`RISKY_HIGH_VIZ_REPLY`、`SPAM_HIGH_RECALL_OON`、`LOW_QUALITY_AND_UQF_DROPS`、
`COMMUNITY_AND_SPAM_DROPS` 这几组规则**只接在通知面**：

| 常量 | 接入点 | surface |
|---|---|---|
| `COMMUNITY_AND_SPAM_DROPS` | `levels.rs:253,292` | `NOTIFICATIONS_WRITER_V2_MENTION`、`_RETWEET_SOURCE` |
| `LOW_QUALITY_AND_UQF_DROPS` | `levels.rs:258,297` | 同上 |
| `RISKY_HIGH_VIZ_REPLY_OON_DROP_UNSPECIFIED` | `levels.rs:259,275` | `_MENTION`、`_MEDIA_TAGGED` |
| `SPAM_HIGH_RECALL_OON_DROP_UNDESIRABLE` | `levels.rs:274` | `_MEDIA_TAGGED` |

`NOTIFICATIONS_WRITER_V2_REPLY = NOTIFICATIONS_WRITER_V2_MENTION`（`levels.rs:262`）。

**这些常量没有接进 `TIMELINE_HOME_RECOMMENDATIONS`（For You）或 `TIMELINE_HOME`（关注流）。**

具体后果：Grox 的 `RISKY_HIGH_VIZ_REPLY` 标签（botmaker 规则 25026，`spamScore >= 0.97`，TTL 14 天）
让**被回复的人收不到通知**，不是把你的回复从 For You 删掉。
「我评论了大号但他没理我」≠「我被限流了」。

### 1.2 A 类的判定边界要说清楚

索引准入调 VF 时**没有观众上下文**：

```
phoenix-rankall-strato/lib/eventProcessing.strato:260-279
  shouldDropTweet(safetyLevel = TimelineHomeRecommendations, forUserId = None)
  出错时默认 false（放行）
```

因为 `forUserId = None`，所有依赖观众的条件（`ViewerFollowsAuthor`、`ViewerBlocksAuthor`、
年龄、设置）**无法按常规解析**。所以：

- 【实证】索引准入用的是推荐级 safety level，且 fail-open。
- 【不公开 / 不可判定】**具体哪些 audience-gated 规则在索引阶段会命中**，本仓库无法确定。不要断言。

---

## 2. 「限流」的准确语义：布尔剥夺，不是分数打折

### 2.1 两个 audience 概念，别混

| audience | 含义 | 谁还能看到 |
|---|---|---|
| `NonFollowers` | 丢给**非粉丝** | 作者本人 + 粉丝正常 |
| `NonAuthors` | 丢给**除作者外所有人** | **只有作者本人**能看到（粉丝也被丢） |

`NonAuthors` 比通常说的「限流」狠得多——它等于对粉丝也隐身。

### 2.2 推荐流和关注流是两套规则

`visibility-filtering-client/vf_client.rs:37-38`：

```rust
TimelineHome = 8,
TimelineHomeRecommendations = 61,
```

信誉标签类的 `NonFollowers` / `NonAuthors` drop 规则挂在 **61（推荐流）**；
**8（关注流）的 user 段没有任何信誉标签规则**。

**所以「限流」= 推荐资格被布尔剥夺**：你的粉丝在关注流里照常看到你，
陌生人再也刷不到你。分数没有被乘 0.1，是**直接不进候选**。

### 2.3 处置严重度折叠（多标签命中时取最严）

`visibility-filtering/rules/action_kind.rs:59-129`：

| ActionKind | severity | 落点 | 实际效果 |
|---|---|---|---|
| `Appealable` | **18** | Fosnr | 可申诉的下架 |
| `Drop` | **17** | Withheld | 不展示 |
| `Tombstone` | **16** | Withheld | 墓碑占位 |
| `LabelInterstitial` | 11 | Slot | 遮罩 + 提示，可穿透 |
| `MediaRestriction` | 10 | Slot(Media) | 媒体受限 |
| `SoftIntervention` | 8 | Fosnr | 软干预 |
| `LimitedEngagement` | **6** | Slot(Engagement) | 只限互动（如回复限制），**不影响展示** |

**注意 6 和 17 的区别**：`LimitedEngagement` 只掐互动能力，帖子照常展示。
看到「你的回复被限制」不等于「你的帖被限流」。

### 2.4 连带删除：最容易踩的坑

`AncillaryVFFilter`：祖先帖 / 被引用帖 / 被转推帖**任一**被判 DROP → 本帖一起删。

而且被引用帖和祖先帖**一律按更严的推荐级送审**，即使你自己的帖是关注内：

| 送审对象 | safety level |
|---|---|
| 关注内帖 + 被转推的原帖 | `TimelineHome`（8，较松） |
| 关注外帖 + **所有祖先帖** + **所有被引用帖** | `TimelineHomeRecommendations`（61，较严） |

证据：`home-mixer/candidate_hydrators/vf_candidate_hydrator.rs:67-106`。

**两条可执行结论**：
1. 引用一条擦边帖，比你自己直接发它更容易出问题。
2. 在一条已被限流的帖下面回复，你的回复会被祖先连带干掉。

---

## 3. 自查路径（按顺序走）

### 第 1 步：用官方透明度工具，别猜

**Under the Hood**：<https://x.com/i/jf/under_the_hood>（`README.md:470`）

能看到：
- 你账号和帖子上**实际被打了哪些影响可见性的标签**（聚合统计）
- **是否有绕过自动系统的人工标签**
- **因法律要求在某国被隐藏**（2026-09-18 更新加入）

生成报告的 job 和 serving 代码在 `under-the-hood/`，渲染页在 `under-the-hood/jetfuel/`。

**这是唯一能看到真实标签的入口。** 任何「我觉得我被限流了」在没有这一步之前都是猜测。

### 第 2 步：分清是 A/B/C/D 哪一类

```
帖子在个人主页能正常打开吗？
├─ 不能 → 账号级处置（封禁/限制），不是推流问题
└─ 能
   ├─ 你的粉丝在「关注」流里刷得到吗？
   │   ├─ 刷不到 → 不是信誉标签限流（8 没有这类规则）
   │   │            查：48h 窗口 / 已读去重 / 会话去重 / 拉黑屏蔽关系
   │   └─ 刷得到，但陌生人刷不到 → B 类，推荐资格被剥夺
   │                                回到第 1 步看标签
   ├─ 只有特定一条帖没曝光，其他正常？
   │   → 查 AncillaryVFFilter：你引用/转推/回复的那条帖是否有问题
   ├─ 回复没曝光？
   │   → 正常。陌生人的回复默认不进推荐池（见 §4.2），不是限流
   └─ 对方说没收到通知？
       → D 类，通知面规则，与 For You 无关
```

### 第 3 步：排除这些「不是限流」的正常机制

| 现象 | 真实原因 | 证据 |
|---|---|---|
| 老帖突然没曝光 | 48 小时硬窗口 | `AgeFilter`，`params/config.rs:41` |
| thread 里只有一条出现 | 一会话只留最高分一条 | `dedup_conversation_filter.rs:19-36` |
| 同时段连发，后面几条量很少 | 作者多样性衰减 0.625 / 0.4375 | `scoring.rs:304-325` |
| 同一条帖第二次刷不到 | 已读 + 已下发去重（10 分钟 / 100 条） | `param.rs:1280,1286` |
| 新帖前 200 曝光后就没量了 | 冷启动池永久退出 | `param.rs:691` |
| 转推/引用莫名消失 | 原帖作者拉黑了你 | `author_socialgraph_filter.rs:24-45` |

## 3.1 申诉

`abuse-ledger-service/` 记录申诉推翻结果，`abuse-enforcement-service` 的 overturn-hold
路径在再次处置前查它，命中则跳过。**但这个闸门默认是关的**：

```rust
// abuse-enforcement-service/service-lib/src/overturn_hold.rs:150-163
mode: GateMode::Off,
on_probe_error: OnProbeError::Allow,
kinds: vec![GateKind::Suspend],
```

【实证】默认 `Off`、默认**只保护封禁类**、查询出错时 **fail-open**（照常处置）。
【不公开】生产是否打开了这个闸门、豁免期具体多长。

所以准确表述是：**申诉推翻会被记录，且在闸门开启时阻止重复施加**——
不是「申诉成功就永久免疫」的无条件保证。

另外 `abuse-enforcement-service` YAML 里的 `12.34` / `12345.67` 是**注释明说的 mock 值**
（`enforcement_user.yaml:20,26`、`enforcement_post.yaml:24,30`），不要当成真实门槛引用。

### 3.2 撤标之后不会立刻恢复

安全标签有缓存，两个方向的延迟不一样（`safety-label-source/dragonfly.rs:248-253`）：

| 缓存条目 | TTL 默认 | 后果 |
|---|---|---|
| `Found`（有标签） | **24 小时**（`:63`） | 标签**被撤掉**后，旧的「有标签」条目最长还能活 24h → **恢复可见可能滞后一天** |
| `NotFound`（无标签） | **1 小时**（`:64`） | 标签**被加上**后，旧的「无标签」条目最长还能活 1h → 处置可能滞后一小时 |

`MIN_TTL = 60s` 地板（`:44`），两者都可被 feature switch 覆盖（`:97-100`）。

**但这是硬过期上界，不是保证延迟。** `due_refresh`（`dragonfly.rs:160-170`）会让
step 0 且年龄 ≥ `REFRESH_AFTER`（60s，`:30`）的条目触发**一次**刷新（step→1，不是持续刷新）；
`refresh_cutoff_ms` 还能强制重填早于 cutoff 的条目。完整的刷新调度循环未在仓库内，
**真实恢复时延无法从本仓库确定**。

可执行的是**方向**：撤标后的滞后来自「有标签」缓存（上界 24h），不是「无标签」缓存。
申诉成功后当天没恢复，先别急着判定申诉无效。

---

## 4. 代码支持的打法【实证】

按杠杆大小排序。

### 4.1 停留时长是当前最大的单项杠杆

| 项 | 权重 | 量级示例 |
|---|---|---|
| `click_dwell_time` | **0.385 / 秒** | 预测点击后停留 10 秒 = **3.85 分** |
| `favorite` | 0.708 | 点赞概率 0.1 = **0.0708 分** |
| `dwell_time` | 0.0075 / 秒 | 未点击的停留，量级小得多 |

证据：`param.rs:549,451,543`。

**差了一到两个数量级。** 而且上游 2026 年 10 月两次更新都在强化时长建模
（10-08 排序模型改进停留时长预测，10-13 召回模型也训练去 surface「读完」的帖）。

可执行：
- 写**需要读完才有价值**的内容，而不是扫一眼就划走的
- 长图文 / 需要展开的内容天然占优（`photo_expand` 也是正头）
- 「点击后停留」比「未点击停留」贵 51 倍（0.385 / 0.0075），**让人点进来**比让人在 feed 里多看两眼更值

### 4.2 原创帖 > 回复 > 转推，差距是结构性的

三条独立机制叠加：

1. **陌生人的回复和转推直接不进推荐池**
   `EnablePhoenixOonReplies = false`（`param.rs:71`），`oon_retweet_reply_filter.rs:16-28`
2. **互关加成只给原创帖**
   `bidirectional_boost_eligible = !is_reply && !is_retweet && is_mutual_follow_author`
   （`xai-value-model/inputs.rs:20-22`）
3. **即使是你关注的人，他的回复/转推也要打 0.75 折**
   `EnableOonRescoreForInNetworkRepliesRetweets = true`（`vm-ranker/params.rs:218-222`）

**所以「多评论少发帖」作为涨粉手段是对的，但机制不是「评论被推荐」。** 见 §5.1。

### 4.3 互关是算法层面唯一明确的「关系红利」

`BidirectionalFollowReplyWeightBoost = 15.0`（`param.rs:458`）
→ 互关作者的**原创帖** reply 权重 **5.0 → 20.0，翻 4 倍**。

兑现链条：
```
去大号评论区串门 → 被作者/读者看到 → 回关 → 形成互关
  → 你的原创帖在对方 For You 里 reply 权重 5 → 20
  → 更容易被推给他 → 更多真实互动 → 进一步扩散
```

注意历史：2026-07-13 推到 20，07-24 回调到 **15**，原因是世界杯期间用户抱怨
看不到足够多关注外讨论（`docs/BIDIRECTIONAL_BOOST_CHANGE.md`）。
**这个值会被调，别把 20 当常量。**

`bidirectional_follow_dwell_weight_boost` 同期测试但**未推广**，生产值 0.0（`param.rs:464`）。

### 4.4 新号：前 200 次曝光是全部试错预算

冷启动资格（全部满足）：

| 条件 | 阈值 | 证据 |
|---|---|---|
| 原创帖（非回复非转推） | 硬性 | `author_cold_start.rs:189-190` |
| 作者粉丝数 ≤ | 50,000 | `param.rs:709` |
| 发布时长 ≤ | 7200 秒（2 小时） | `param.rs:715` |
| 该帖首页曝光 < | **200** | `param.rs:691` |

**每次请求只有 1 个名额**，抬到第 16 位（`ColdStartSlotMin=15, Max=16`，`param.rs:697,703`）。
选谁用 Thompson 采样，先验 `Beta(0.75, 49.25)` → 均值 1.5% 点赞率（`param.rs:741,747`）。

可执行：
- **新号不要发回复和转推**，它们拿不到冷启动名额
- 前 2 小时是窗口，**发布时间要挑你的目标受众在线的时候**【推测：受众在线时段本身无代码证据，但 2 小时窗口是实证】
- 一旦曝光超 200 就永久退出，**没有第二次机会**
- 0 曝光的帖在采样里会胜过 10000 曝光 0 赞的帖（`author_cold_start.rs:988-1007`）——不确定性红利真实存在

### 4.5 别在同一时段连发，别刷长 thread

| 行为 | 后果 | 证据 |
|---|---|---|
| 同时段第 2 条 | × 0.625 | `scoring.rs:304-325`，decay 0.5 / floor 0.25 |
| 同时段第 3 条 | × 0.4375 | 同上 |
| 同一 thread 连发 5 条 | For You 里**最多 1 条** | `dedup_conversation_filter.rs:19-36` |

**长 thread 不会为你争取更多曝光位。** 想要多个坑，必须是**不同 conversation** 且**分散时段**。

### 4.6 别引用/转推擦边内容

见 §2.4。被引用帖按推荐级严审 + 连带删除。
**这是风控里性价比最差的冒险**：你承担的是别人内容的风险。

### 4.7 组织互赞群 / 举报群无效

`xai-value-model/scoring.rs:46-58` 官方原文：

> For an account to count in the algorithms recommendation system, it must take place on a post served in Home Timeline. Directly navigating to a post (i.e., coordinating via groupchat) has no ranking impact.

**群里发链接组织人去点赞/举报，对排序无影响**，因为动作不发生在 For You 里。
同理，恶意举报主要影响**和举报者相似的人**的推荐（预测是个性化的），不是全网降权。

### 4.8 蓝 V 的真实作用：进 PageRank 传送种子集

**不是排序加权。** 排序权重表里没有任何 verified 相关项。

真实机制在账号信誉模型：

```scala
// user-cred-v2/UserCredV2App.scala:174
validUserInfoPipe.filter(u => !u.isNearZero && u.isPremium).map(u => UserMass(u.id, 1.0))
// user-cred-v2/ValidUserInfo.scala:14-15
def isPremium = isBlueVerified || isGrayVerified || isGoldVerified || isVerifiedOrg || isVOAffiliate
```

teleport 向量 = `(1 - beta) × 归一化 uniform + beta × 归一化 engagement`，
`beta = engagement_teleport_beta = 0.5`（`UserCredV2Config.scala:35,183`）。

**uniform 那一半只发给认证账号。** 所以买蓝 V 确实把你放进了信誉模型的种子集，
抬高你的 PageRank 基线——而 PageRank 是风控豁免门槛的输入
（`botmaker-rules/scarecrow/derived-feature/HighPageRankThreshold.df:2` = **54**，
`grox/flows/reply_spam/constants.py:9` = **66**）。

**准确表述**：蓝 V 影响的是**你被风控打标的概率**，不是**你的帖子的排序分**。
这两件事经常被混为一谈。

### 4.9 热门池是大号专属，新号别指望

`TOP_POSTING_AUTHORS_FRACTION = 0.00005`（`home-mixer/util/popular_authors.rs:11`）
→ 近 7 天活跃发帖者中按粉丝数排序的**前 0.005%**，每小时刷新。

新号只能靠 Phoenix 召回、SimClusters 和冷启动名额。

---

## 5. 常见误解纠正

### 5.1 「多串门评论，算法会推荐你的评论」——半对

**对的部分**：串门评论确实能涨粉。
**错的部分**：机制不是算法推荐你的评论。

你的回复**不会**被推荐给陌生人（`EnablePhoenixOonReplies = false`）。它的曝光完全来自：
- 打开那条帖详情页的人读到评论区（**人工曝光**）
- 你自己的粉丝在 For You 里看到（关注内回复可进，但 × 0.75）
- 被回复的作者收到通知（**且这条可能被 D 类规则掐掉**）

算法层面的兑现在**互关之后你的原创帖**上（§4.3）。

**所以「只评论不发帖」是错的**：评论建立关系，但关系红利只能由原创帖领取。
两者必须配合。

### 5.2 「1 个举报抵消 468 个赞」——错

权重乘的是**预测概率**，不是计数。`xai-value-model/scoring.rs:34-44` 专门写注释纠正这条。
而且当前 `report / favorite = 234 / 0.708 ≈ 330`，468 是旧值。
**但即使 330 也不能读成计数等价**——举报的 baseline 概率比点赞低 1000 倍以上，
高权重是为了让稀有事件能影响排序。

### 5.3 「新号有发帖门槛 / 新号被限流」——错

home-mixer 两个「新号」过滤器**默认都关闭**：
- `EnableNewUserMinEngagementFilter = false`（`param.rs:937-941`）
- `EnableNewUserSoftNsfwFilter = false`（`param.rs:967-971`）

而且即使开启，其中的「新号」指**观众**不是作者：

```rust
// home-mixer/filters/new_user_min_engagement_filter.rs:70-77
duration_since_creation_opt(query.user_id)   // ← query.user_id 是观众
```

它是「新观众内容质量保护」，不是「新作者分发限制」。
**新号真正的算法待遇是冷启动扶持（§4.4），是正向的。**

### 5.4 「外链会被降权」——排序代码里没有这个惩罚

`home-mixer/params/param.rs` 中**没有**外链惩罚参数；`open_link` 是**正头**，权重 0.2（`param.rs:480`）。

但要分清：`UNTRUSTED_URL` 是**安全标签**，走可见性/通知面，不是排序降权。
【实证】排序无外链惩罚。【推测】带外链的帖点击后停留可能更短（用户跳走了），
从而间接损失 `click_dwell_time` 分——**这是机制推断，代码没有直接证据**。

### 5.5 「发推时间 / hashtag 数量 / 关键词密度有玄学」——无代码证据

本仓库的排序输入里**没有**发布时段、hashtag 计数、关键词密度这类特征工程项。
Phoenix 的输入是**你的行为序列 + 帖子内容 embedding**（见 `07-models`）。

【不公开】Grox 的 LLM prompt（具体 j2 文件）未放出，所以内容理解层到底提取了什么特征
**无法穷举**。不要断言「没有」，只能说「排序权重表里没有」。

### 5.6 「被限流就是分数被调低」——错

见 §2.2。是**布尔剥夺推荐资格**，不是乘一个小于 1 的系数。
诊断方式完全不同：查标签，不是查分数。

### 5.7 「作者降权 / OON 折扣在 home-mixer 里」——读错了模块

home-mixer 把作者多样性**硬编码 false**（`home-mixer/scorers/value_model.rs:46-49`），
真正生效在 vm-ranker（`vm-ranker/scoring/value_model.rs:109-114`）。
只看 home-mixer 会误判为「没有作者降权」。

另外 `vm-ranker/params.rs` 顶部**没有 sync 注释**，其 `FavoriteWeight` 写 0.5，
而 home-mixer 已同步为 0.708（`param.rs:448-452`）。两者读**同一个 switch key**
`rust_home_mixer_favorite_weight`。**生产值一律以 home-mixer 为准。**

---

## 6. 明确不能从代码得出的结论【不公开】

上游 README `What's not in this repo?` 承认，为降低被绕过风险刻意未放出：

| 缺口 | 影响 |
|---|---|
| **Grox 的 LLM prompt**（j2 文件） | 无法穷举内容理解层提取了哪些特征 |
| **部分 botmaker 规则** | 无法列出全部打标触发条件 |
| `abuse-enforcement-service` 真实阈值 | YAML 里 `12.34` / `12345.67` 是注释明说的 mock 值 |
| `bdsm/runtime/sink_policy.yaml` 操作点 | 全是哨兵 `9.99`（概率）/ `999999`（计数）；**头名、结构、动作映射是真的，阈值不是** |
| 索引阶段 audience 解析 | `forUserId = None`，无法确定哪些观众相关规则命中 |

**遇到这些问题，正确回答是「不公开」，不是推断机制。**

补偿手段就是 Under the Hood（§3 第 1 步）——它给的是**你账号上的实际结果**，
比推断规则更可靠。

---

## 7. 一页速查

| 想做的事 | 代码怎么说 | 去哪篇 |
|---|---|---|
| 提高单帖曝光 | 最大化点击后停留时长（0.385/秒） | `02-scoring-ranking` §2.2 |
| 涨粉 | 串门建互关 → 原创帖领 4 倍 reply 权重 | `02` §3 + 本篇 §5.1 |
| 新号起步 | 只发原创帖，抓前 2 小时 / 前 200 曝光 | `02` §4.3 + 本篇 §4.4 |
| 一天发几条 | 分散时段；同时段第 2 条打 6.25 折 | `02` §4.1 |
| 要不要发长 thread | For You 里只留 1 条，不增加坑位 | `03-retrieval-filtering` §3.1 |
| 要不要引用热帖 | 被引用帖按严档审 + 连带删除，风险高 | `03` §3.2-3.3 |
| 买蓝 V 有用吗 | 进 PageRank 种子集，降低被打标概率；**不加排序分** | 本篇 §4.8 |
| 组织互赞群 | 无效，动作必须发生在 For You 内 | 本篇 §4.7 |
| 怀疑被限流 | 先开 Under the Hood 看标签，再分 A/B/C/D | 本篇 §1 + §3 |
| 回复没人理 | 可能只是通知被掐，不是推流问题 | 本篇 §1.1 |