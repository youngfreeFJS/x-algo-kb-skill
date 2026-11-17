# 03 · 召回与过滤：一条推文能不能进池子

> 证据基准：`home-mixer/candidate_pipeline/phoenix_candidate_pipeline.rs`、`home-mixer/filters/*`、`home-mixer/params/param.rs`

**排序决定顺序，过滤决定生死。** 一条推文如果被过滤掉，分数再高也没用。而过滤分两道：打分前（省算力）和排序后（可见性风控）。

---

## 1. 召回源与配额（生产默认值）

| 召回源 | 类型 | 配额 | 启用 | 证据 |
|---|---|---|---|---|
| **Thunder** | 关注内，内存实时池 | **1200** | 是 | `param.rs:27` |
| **Phoenix 召回** | 关注外，双塔向量检索 | **1000** | 是 | `param.rs:8` |
| Phoenix 冷启动召回 | 关注外，新帖专用 | **200** | 是 | `param.rs:20` |
| **SimClusters** | 关注外，社区聚类 | — | 是 | `param.rs:52` |
| **Popular posts** | 关注外，共享热门池 | **500** | 是 | `param.rs:1251` |
| Phoenix MOE | 关注外，实验 | 0 | **否** | `param.rs:192,216` |
| TweetMixer | — | 800 | **否** | `param.rs:45` |
| SID（语义 ID） | — | 800 | **否** | `param.rs:848` |

SimClusters 候选年龄上限 **48 小时**（`param.rs:842`）。

### 1.1 打分预算与「公平分配」

进入 Phoenix 打分的候选上限：**2800 条**（`PhoenixScoresResultSize`，`param.rs:1513`）。

候选超预算时，`FairShareRankingFilter` 按**召回源比例**削减，而不是全局取 top（`home-mixer/filters/fair_share_ranking_filter.rs:59-101`，最大余额法）：

```rust
// fair_share_ranking_filter.rs:90-101
let groups = group_by_served_type(candidates);   // 按召回源分组
let keep = fair_share_counts(&demands, budget);  // 各组按比例分配 2800 名额
```

单测示例（`fair_share_ranking_filter.rs:135-158`）：关注内 440 + SimClusters 220 + Phoenix 440 = 1100 条，预算 1000 → 保留 400 / 200 / 400，**每个源都按同比例 90.9% 削减**。

**含义**：某个召回源暴涨不会挤掉其他源。关注外内容不会因为量大就淹没关注内内容。

### 1.2 热门作者池怎么选的

`home-mixer/util/popular_authors.rs:11,25-43`：

```rust
pub const TOP_POSTING_AUTHORS_FRACTION: f64 = 0.00005;
let k = (active_posters_7d as f64 * fraction).ceil();
Ok(by_followers_desc[..k].to_vec())
```

取**近 7 天活跃发帖者中，按粉丝数排序的前 0.005%**。每小时刷新一次（`REFRESH_INTERVAL_MS = 60*60*1000`，`popular_authors.rs:8`）。

**含义**：热门池是大号专属通道，新号进不去。新号只能靠 Phoenix 召回、SimClusters 和冷启动名额。

---

## 2. 打分前过滤（按真实执行顺序）

权威顺序来自 `home-mixer/candidate_pipeline/phoenix_candidate_pipeline.rs:433-455`：

| # | 过滤器 | 干掉什么 | 关键细节 |
|---|---|---|---|
| 1 | `DropDuplicatesFilter` | 多源返回的同一帖 | |
| 2 | `ZeroFavCodivertFilter` | 实验分桶用 | 默认关（`ViewerZeroFavCodivertIsTreatment=false`） |
| 3 | `CoreDataHydrationFilter` | 正文/元数据加载失败的 | |
| 4 | `NewUserSoftNsfwFilter` | 新观众 + 软色情 | 默认关（`param.rs:970`）；阈值账号 7 天内、行为序列 <100 |
| 5 | **`AgeFilter`** | **超过 48 小时的帖** | `MAX_POST_AGE = 48*60*60`，`params/config.rs:41` |
| 6 | `SelfTweetFilter` | 你自己的帖 | |
| 7 | **`OONRetweetReplyFilter`** | **陌生人的转推和回复** | 见下方 §2.1，最重要 |
| 8 | `OONNsfwSimclustersFilter` | SimClusters 里色情标记账号的关注外帖 | `oon_nsfw_simclusters_filter.rs:19-24` |
| 9 | `RetweetDeduplicationFilter` | 同一帖的重复转推 | |
| 10 | `IneligibleSubscriptionFilter` | 你没订阅的订阅专属帖 | `ineligible_subscription_filter.rs:22-26` |
| 11 | `PreviouslySeenPostsFilter` | 已展示过的 | |
| 12 | `PreviouslySeenPostsBackupFilter` | 同上，第二份曝光记录 | |
| 13 | `PreviouslyServedPostsFilter` | 本次会话已下发过的 | 连**引用/转推/祖先**一起查（`related_post_ids_iter`） |
| 14 | `ViewerMutedKeywordFilter` | 命中你屏蔽的关键词 | |
| 15 | `AuthorSocialgraphFilter` | 拉黑/屏蔽关系 | 见 §2.2，范围比想象的大 |
| 16 | `VideoFilter` | 请求排除视频时的视频帖 | |
| 17 | `TopicIdsFilter` | 话题请求外的帖 | |
| 18 | `NewUserMinEngagementFilter` | 新观众看低互动关注外帖 | 默认关，见 §2.3 |
| 19 | `InventoryHoldoutFilter` | 按百分比随机扣留 | 默认关，三个 percent 都是 0（`param.rs:1160-1178`） |
| 20 | `FavHoldoutFilter` | 按点赞数决定扣留比例 | 默认关（`param.rs:1185`） |
| 21 | **`FairShareRankingFilter`** | 超 2800 预算的部分 | 按源比例削，见 §1.1 |

### 2.1 最重要的一条：陌生人的回复进不了推荐池

`home-mixer/filters/oon_retweet_reply_filter.rs:16-28`：

```rust
let allow_phoenix_oon_replies = query.params.get(EnablePhoenixOonReplies);  // 默认 false
let root_only = query.params.get(PhoenixOonRepliesRootOnly);
FilterResult::partition(candidates, |c| {
    let is_reply = c.in_reply_to_tweet_id.is_some();
    let is_retweet = c.retweeted_tweet_id.is_some();
    let oon_reply_dropped = is_reply
        && !(allow_phoenix_oon_replies && is_phoenix_home_retrieval(c) && (!root_only || replies_to_root));
    !((c.in_network == Some(false) && (is_retweet || oon_reply_dropped))
        || (is_reply && c.ancestors.is_empty()))
})
```

拆解成三条硬规则：

1. **没关注的作者发的转推 → 直接丢**
2. **没关注的作者发的回复 → 直接丢**（`EnablePhoenixOonReplies = false`，`param.rs:71`）
3. **任何回复，只要祖先链缺失 → 直接丢**（无论关注与否）

**这直接决定了「串门评论」的真实作用机制**：

你的回复**不会**被算法推荐给陌生人。它的曝光完全来自：
- 打开那条帖子详情页的人（含大号粉丝）读到评论区
- 你自己的粉丝在 For You 里看到（关注内回复可以进，但要打 0.75 折，见 `02-scoring-ranking` §4.2）
- 被回复的作者本人收到通知

所以串门是**人工曝光 + 关系建设**，不是「让算法推荐你的评论」。算法层面的兑现发生在**互关之后你的原创帖**上。

### 2.2 社交关系过滤的范围比想象的大

`home-mixer/filters/author_socialgraph_filter.rs:24-45`，命中任一即丢：

- 你屏蔽（mute）了作者
- 你拉黑（block）了作者
- **作者拉黑了你**
- **被引用帖的作者拉黑了你**
- 你拉黑了被引用帖作者
- 你拉黑了被转推帖作者

**含义**：一条转推/引用会因为**原帖作者**和你的关系而被连带干掉，不只是转推者。

### 2.3 「新用户」过滤器说的是观众，不是作者

容易读错的地方。`home-mixer/filters/new_user_min_engagement_filter.rs:70-77`：

```rust
fn within_account_age(query: &ScoredPostsQuery) -> bool {
    duration_since_creation_opt(query.user_id)   // ← query.user_id 是观众
        .map(|age| age < Duration::from_secs(max_age_secs))
}
```

判定的是**观众账号**年龄 < 1800 秒（30 分钟）或复活窗口内，然后过滤掉互动率 < 0.004 的**关注外**候选（`new_user_min_engagement_filter.rs:60-68`，`in_network != Some(false)` 直接放行）。

生产**默认关闭**（`EnableNewUserMinEngagementFilter = false`，`param.rs:940`）。

**这不是「新号发帖门槛」，是「新观众内容质量保护」。** 别误读成对新作者的限制。

---

## 3. 排序后过滤（可见性风控在这里生效）

顺序来自 `phoenix_candidate_pipeline.rs:516-520`：

| # | 过滤器 | 作用 |
|---|---|---|
| 1 | **`VFFilter`** | 删掉 visibility-filtering 判 DROP 的帖 |
| 2 | **`AncillaryVFFilter`** | 祖先 / 被引用 / 被转推的帖被 DROP → 本帖连带删 |
| 3 | `AncestorVideoFilter` | 祖先视频相关 |
| 4 | **`DedupConversationFilter`** | **一个会话只留最高分的一条** |
| 5 | `VideoCarouselFilter` | 视频轮播相关 |

### 3.1 会话去重：一个 thread 只有一个坑

`home-mixer/filters/dedup_conversation_filter.rs:19-36`：

```rust
let conversation_id = get_conversation_id(&candidate);  // 祖先里最小的 id，即根帖
if let Some((kept_idx, best_score)) = best_per_convo.get_mut(&conversation_id) {
    if score > *best_score { /* 换成新的，旧的移除 */ }
    else { /* 移除新的 */ }
}
```

**含义**：你在同一个 thread 里连发 5 条，For You 里最多出现 1 条（分最高的那条）。**长 thread 不会为你争取更多曝光位。**

### 3.2 连带删除

`AncillaryVFFilter`：只要祖先帖、被引用帖、被转推帖中任何一个被判 DROP，本帖也删。

**含义**：引用一条违规帖，你自己的帖也会被连带干掉。转推同理。**这是风控里最容易踩的坑。**

### 3.3 两档审查标准：被引用帖永远按更严的标准查

`home-mixer/candidate_hydrators/vf_candidate_hydrator.rs:67-106` 把候选分成两批，用**不同的 safety level** 送去 VF：

| 送审对象 | safety level | 严格程度 |
|---|---|---|
| 关注内帖 + **被转推的原帖** | `TimelineHome` | 较松 |
| 关注外帖 + **所有祖先帖** + **所有被引用帖** | `TimelineHomeRecommendations` | **较严** |

```rust
// vf_candidate_hydrator.rs:76-84
for &ancestor_id in &candidate.ancestors { oon_ids.push(ancestor_id); }
if let Some(quoted_id) = candidate.quoted_tweet_id { oon_ids.push(quoted_id); }
if let Some(retweeted_id) = candidate.retweeted_tweet_id { in_network_ids.push(retweeted_id); }
```

**含义**：即使你自己的帖是发给自己粉丝看的（关注内），你**引用的那条帖**仍然按「推荐级」的严格标准审查。引用一条擦边内容，比直接发它更容易连带出问题。

注意祖先帖也一律走严格档，所以**在一条被限流的帖下面回复，你的回复会被祖先连带干掉**。

---

## 4. 会话级去重与已读机制

已读被处理两次（README `Filtering` 节 + `param.rs`）：

- `ThunderSource` 直接收到已读列表，在召回时就不返回
- 其他源不传，靠 `PreviouslySeenPostsFilter` / `PreviouslySeenPostsBackupFilter` 兜

已下发排除窗口：**10 分钟 / 100 条**（`ExcludeServedTweetIdsDuration=10`，`ExcludeServedTweetIdsNumber=100`，`param.rs:1280,1286`）

缓存帖上限 **750 条**（`MaxPostsToCache`，`param.rs:790`），Phoenix 请求缓存 TTL **10800 秒 = 3 小时**（`param.rs:1219`）。

---

## 5. 一张漏斗图（数量级）

```
Thunder 1200（关注内）
Phoenix 1000 + 冷启动 200（关注外）
SimClusters ?（关注外）
Popular 500（关注外）
        │  合计约 3000+
        ▼
21 道打分前过滤（48h / 陌生人回复转推 / 已读 / 屏蔽 / 订阅…）
        ▼
FairShareRankingFilter → 上限 2800，按源比例削
        ▼
Phoenix transformer 打分（候选之间互不可见）
        ▼
vm-ranker 重算：× 作者多样性 × OON 0.75 + 冷启动抬升 1 个名额
        ▼
DPP 多样性重排（theta 0.65，最多影响前 150）
        ▼
TopKScoreSelector 取 top K
        ▼
VFFilter / AncillaryVFFilter（风控 DROP）
DedupConversationFilter（一会话一条）
        ▼
BlenderSelector 混入广告 / Who to Follow / prompts
        ▼
最终 For You
```

**注意风控在最后**：一条帖可能分数很高、排到第 3 位，然后被 VF 判 DROP 直接消失。排序和可见性是两套独立系统（README `Key Design Decisions` 第 4 条）。