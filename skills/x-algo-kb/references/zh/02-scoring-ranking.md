# 02 · 打分与排序：一条推文凭什么排在前面

> 证据基准：`xai-value-model/scoring.rs`、`xai-value-model/weights.rs`、`home-mixer/params/param.rs`、`vm-ranker/params.rs`
> `home-mixer/params/param.rs:1` 注明 `last sync 2026-11-16T16:00:37Z`，即本文数值为**当前生产默认值**。

---

## 1. 一句话公式

```
最终分 = Σ(权重_i × 模型预测的「你会做动作_i 的概率」) + 0.001
        然后 × 作者多样性系数 × 关注外折扣
        最后交给 DPP 做多样性重排
```

**最重要的认知纠正**：权重乘的是**预测概率**，不是**实际互动计数**。

`xai-value-model/scoring.rs:34-44` 原文注释：

> Each weight multiplies the *predicted* probability of that action (P(favorite), P(repost), …) or a continuous value e.g. watch time -- the weights do not multiply raw engagement counts. One common misinterpretation is that you can read these weight ratios as count equivalences, e.g. the incorrect statement that "one report cancels 468 likes" -- this is incorrect.

所以「1 个举报抵消 468 个赞」是**错的**。Report 权重高是因为举报本身极其稀有（注释说 baseline 概率比点赞低 1000 倍以上），不高权重就完全影响不了排序。

---

## 2. 完整权重表（生产默认值）

### 2.1 正向动作

| 动作头 | 权重 | 参数名 | 证据 |
|---|---|---|---|
| `reply` 回复 | **5.0** | `rust_home_mixer_reply_weight` | `param.rs:453` |
| `quote` 引用 | **5.0** | `rust_home_mixer_quote_weight` | `param.rs:502` |
| `share_via_dm` 私信分享 | **5.0** | `rust_home_mixer_share_via_dm_weight` | `param.rs:493` |
| `follow_author` 关注作者 | **4.0** | `rust_home_mixer_follow_author_weight` | `param.rs:519` |
| `share` 分享 | 2.118 | `rust_home_mixer_share_weight` | `param.rs:488` |
| `retweet` 转推 | 1.0 | `rust_home_mixer_retweet_weight` | `param.rs:466` |
| `favorite` 点赞 | **0.708** | `rust_home_mixer_favorite_weight` | `param.rs:451` |
| `click` 点击帖子 | 0.274 | `rust_home_mixer_click_weight` | `param.rs:479` |
| `open_link` 打开外链 | 0.2 | `rust_home_mixer_open_link_weight` | `param.rs:480` |
| `dwell` 停留（二值） | 0.05 | `rust_home_mixer_dwell_weight` | `param.rs:501` |
| `photo_expand` 展开图片 | 0.05 | `rust_home_mixer_photo_expand_weight` | `param.rs:471` |
| `quoted_click` 点击被引用帖 | 0.05 | `rust_home_mixer_quoted_click_weight` | `param.rs:507` |
| `post_unexplored` 探索未读 | 0.015 | `rust_home_mixer_post_unexplored_weight` | `param.rs:525` |
| `video_open` 打开视频 | **0.0** | — | `param.rs:477` |
| `profile_click` 点击头像 | **0.0** | — | `param.rs:485` |
| `vqv` 视频优质观看 | **0.0** | — | `param.rs:487` |
| `share_via_copy_link` 复制链接 | **0.0** | — | `param.rs:499` |
| `quoted_vqv` | **0.0** | — | `param.rs:513` |
| `post_video` | **0.0** | — | `param.rs:531` |
| `grok_analyze` | **0.0** | — | `param.rs:537` |

### 2.2 连续值（时长类，单位秒）

| 项 | 权重 | 证据 |
|---|---|---|
| `click_dwell_time` 点击后停留时长 | **0.385** | `param.rs:549` |
| `dwell_time` 停留时长 | **0.0075** | `param.rs:543` |
| `video_continuation` 视频续看 | 0.0（home-mixer 硬编码） | `value_model.rs:39` |
| `user_video_continuation` | 0.0（硬编码） | `value_model.rs:40` |
| `profile_visit_secs` 主页停留 | 0.0（硬编码） | `value_model.rs:41` |

**注意量级**：`click_dwell_time` 权重 0.385/秒。预测点击后停留 10 秒 = 3.85 分，而点赞概率 0.1 = 0.0708 分。**停留时长的贡献比点赞大一到两个数量级**。这是当前算法最被低估的一项。

### 2.3 负向动作

| 动作头 | 权重 | 证据 |
|---|---|---|
| `report` 举报 | **-234.0** | `param.rs:570` |
| `mute_author` 屏蔽作者 | **-58.8** | `param.rs:568` |
| `not_interested` 不感兴趣 | **-53.07** | `param.rs:556` |
| `block_author` 拉黑作者 | **-31.2** | `param.rs:562` |
| `not_dwelled` 划走没停留 | -0.02 | `param.rs:575` |

`report / favorite = 234 / 0.708 ≈ 330`（README 里写的 468 是旧值，注释未同步更新）。

### 2.4 为什么拉黑/举报刷不动你

`xai-value-model/scoring.rs:46-58` 给了两条官方解释：

1. **个性化**：预测的是「这个观众会不会举报」，不是累加计数。恶意账号的举报主要影响**和恶意账号相似的人**的推荐，不影响所有人。
2. **必须是首页信息流里发生的动作才算**：
   > For an account to count in the algorithms recommendation system, it must take place on a post served in Home Timeline. Directly navigating to a post (i.e., coordinating via groupchat) has no ranking impact.

**这条极其关键**：群里发链接组织人去举报/点赞，**对排序无影响**，因为那些动作不是发生在 For You 里。同理，组织互赞群刷赞也不进排序信号。

---

## 3. 互关加成（bidirectional boost）——2026 年 7 月那次大改

### 3.1 机制

```rust
// xai-value-model/weights.rs:127-134
pub fn reply_weight_for(&self, candidate) -> f64 {
    if boost != 0.0 && candidate.bidirectional_boost_eligible() {
        return self.reply + self.bidirectional_follow_reply_weight_boost;
    }
    self.reply
}
```

生产值：`BidirectionalFollowReplyWeightBoost = 15.0`（`param.rs:458`）

**互关作者的原创帖，reply 权重从 5.0 → 20.0，翻 4 倍。**

### 3.2 生效条件（三个必须同时满足）

```rust
// xai-value-model/inputs.rs:20-22
pub fn bidirectional_boost_eligible(&self) -> bool {
    !self.is_reply && !self.is_retweet && self.is_mutual_follow_author
}
```

1. **不是回复**
2. **不是转推**
3. **双向关注**（你关注他 && 他关注你）

判定实现在 `home-mixer/candidate_hydrators/bidirectional_follow_hydrator.rs`：先取观众的关注列表，再对候选作者调 `check_followed_by` 反向确认。

### 3.3 官方公布的时间线

`docs/BIDIRECTIONAL_BOOST_CHANGE.md`：

| 日期 | 变更 |
|---|---|
| 2026-07-10 | A/B 测试，boost 值随机分配 5 / 10 / 15 / 20，多数用户为 0 |
| 2026-07-13 | 效果好，向大量用户推 **20** |
| 2026-07-24 | 降到 **15**。原因：世界杯期间用户抱怨看不到足够多讨论，因为很多帖子来自没关注的账号 |

`bidirectional_follow_dwell_weight_boost` 同期测试但**未推广**，生产值 0.0（`param.rs:464`）。

### 3.4 运营含义

这是「串门评论涨粉」在算法上真正的兑现路径：

```
去大号评论区串门
  → 被作者/其他读者看到 → 回关
  → 形成互关
  → 你的「原创帖」在对方 For You 里 reply 权重 5 → 20
  → 更容易被推给他 → 更多真实互动 → 进一步扩散
```

**注意**：加成给的是**你的原创帖**，不是你的回复。回复本身不享受加成，也不进推荐池（见 `03-retrieval-filtering`）。

---

## 4. 三个乘法调整

### 4.1 作者多样性衰减（防刷屏）

```rust
// xai-value-model/scoring.rs:304-306
pub fn diversity_multiplier(decay_factor, floor, exponent) -> f64 {
    (1.0 - floor) * decay_factor.powf(exponent) + floor
}
```

生产参数（`vm-ranker/params.rs:200-216`）：`enable=true`, `decay=0.5`, `floor=0.25`

`exponent = k` = 这条帖在**同作者所有候选中按分数排序的序号**（`scoring.rs:308-325`）。

| 同作者第几条 | k | 系数 |
|---|---|---|
| 第 1 条 | 0 | **1.000** |
| 第 2 条 | 1 | **0.625** |
| 第 3 条 | 2 | **0.4375** |
| 第 4 条 | 3 | 0.34375 |
| 第 5 条 | 4 | 0.296875 |
| 第 N 条 | → | 趋近 **0.25**（地板） |

**运营含义**：同一时段连发多条，第 2 条就打 6.25 折，第 3 条 4.4 折。**一天多条不如把内容拆到不同时段**，且每个时段只有最强的一条能拿到满权重。

### 4.2 关注外折扣（OON discount）

生产值 `OonWeightFactor = 0.75`（`vm-ranker/params.rs:242-246`）

生效范围（`xai-value-model/scoring.rs:327-336`）：

```rust
fn oon_applies(weights, candidate) -> bool {
    match candidate.in_network {
        Some(false) => true,                          // 没关注的作者 → 打折
        Some(true) => weights.oon_rescore_in_network_replies_retweets
                      && (candidate.is_reply || candidate.is_retweet),  // 关注了，但是回复/转推 → 也打折
        None => false,
    }
}
```

`EnableOonRescoreForInNetworkRepliesRetweets = true`（`vm-ranker/params.rs:218-222`）

**所以：即使是你关注的人，他发的回复和转推也要打 0.75 折。只有原创帖拿满权重。**

话题请求单独更狠：`TopicOonWeightFactor = 0.5`（`vm-ranker/params.rs:236-240`）

新用户专属：`NewUserOonWeightFactor = 0.00001`（几乎等于彻底关掉关注外内容），但 `NewUserAgeThresholdSecs = 0` → **当前未启用**（`vm-ranker/params.rs:248-258`）。启用条件还要求 `viewer_following_count >= 5`（`vm-ranker/scoring/value_model.rs:21,144-146`）。

### 4.3 冷启动扶持（新号唯一的算法外挂）

实现：`home-mixer/scorers/author_cold_start.rs`

**资格门槛（全部满足才入围）**，`author_cold_start.rs:188-193` + `296-309`：

| 条件 | 生产阈值 | 证据 |
|---|---|---|
| 必须是原创帖（非回复、非转推） | 硬性 | `author_cold_start.rs:189-190` |
| 作者粉丝数 ≤ | **50,000** | `param.rs:709` |
| 帖子发布时长 ≤ | **7200 秒（2 小时）** | `param.rs:715` |
| 该帖首页曝光数 < | **200** | `param.rs:691` |
| 当前排名位置 < | 非零候选数 × **0.97** | `param.rs:722` |
| 非话题请求 | 硬性 | `author_cold_start.rs:384` |

**名额：每次请求只有 1 条帖子被抬升。**

```rust
// author_cold_start.rs:216-226
let rank = rand::rng().random_range(lo..hi);   // lo=15, hi=16 → rank 恒为 15
Some((rank, ranked[rank]))
// author_cold_start.rs:331
effective[best_idx] = effective[best_idx].max(target);
```

`ColdStartSlotMin=15`, `ColdStartSlotMax=16`（`param.rs:697,703`）→ 抬到**第 16 位**（0-indexed 15）的分数。

**选谁：Thompson 采样**（`author_cold_start.rs:243-283`）

```rust
let n = scale * view_count_on_home;        // 首页曝光
let x = min(fav_count, n);                // 点赞数
Beta(alpha0 + x, beta0 + (n - x)).sample()
```

`alpha0 = 0.75`, `beta0 = 49.25`（`param.rs:741,747`）→ 先验均值 `0.75/50 = 1.5%` 点赞率。
先按采样值取 `top_k = 2`（`param.rs:753`），再在这 2 条里选**模型分最高**的那条。

**含义**：曝光少的新帖有不确定性红利（测试显示 0 曝光的帖会胜过 10000 曝光 0 赞的帖，`author_cold_start.rs:988-1007`）；但一旦曝光超 200 就永久退出冷启动池。**新帖的前 200 次曝光就是全部试错预算。**

---

## 5. 打分链路的真实执行顺序（容易读错的地方）

README 说三个调整都在 `RankingScorer` 里，但代码不是这样：

| 阶段 | 位置 | 作者多样性 | OON 折扣 |
|---|---|---|---|
| home-mixer 本地打分 | `home-mixer/scorers/value_model.rs:46-49` | **硬编码 false** | `ctx` 默认 1.0，不打折 |
| vm-ranker 重算 | `vm-ranker/scoring/value_model.rs:109-114` | **params 读取，true** | **0.75** |

home-mixer 在请求里强制置 `compute_value_model: true`（`home-mixer/scorers/vm_ranker_request.rs:67`），vm-ranker 收到后用自己的参数**重算一遍**（`vm-ranker/scoring/mod.rs:45-46`）。

**所以三个乘法调整实际发生在 vm-ranker，不在 home-mixer。** 只看 home-mixer 会误判为「没有作者降权」。

另一个坑：`vm-ranker/params.rs` 顶部**没有** sync 注释，其 `FavoriteWeight` 默认写 0.5，而 home-mixer 已同步为 0.708。两者读的是**同一个 feature switch key** `rust_home_mixer_favorite_weight`，生产取同一个值；repo 里的默认值差异只是 vm-ranker 那份没被 cron 同步。**以 `home-mixer/params/param.rs` 为准。**

---

## 6. 负分压缩：一个容易忽略的设计

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

`NEGATIVE_SCORES_OFFSET = 0.001`（`weights.rs:4`）

- 净正分 → 加 0.001，落在 `(0.001, +∞)`
- 净负分 → 线性压缩进 `(0, 0.001)` 这个极窄区间

**含义**：任何预测净负分的帖子，都被压到所有净正分帖子之下，且负分之间差异被极度压平。「负分有多负」几乎不影响排序，**只要跨过 0 这条线就基本判死**。

---

## 7. 未启用的实验能力（读代码时别当成现状）

| 能力 | 开关 | 生产值 |
|---|---|---|
| 乘法式融合 `skip × engage × time` | `ValueModelMode` | `"weighted"`（加法）`param.rs:593` |
| `not_dwelled` 幂次惩罚 | `NotDwelledPowerExponent` | `0.0` → 关闭 `param.rs:581` |
| 权重随机扰动（每人不同权重） | `WeightPerturbationSigma` | `0.0` → 关闭 `vm-ranker/params.rs:191` |
| 页面级 RL 探索 | `EnablePageRlExploration` | `false` `param.rs:373` |
| 页面解码重排 | `EnablePageDecodeRerank` | `false` `param.rs:343` |
| 新用户 OON 近乎归零 | `NewUserAgeThresholdSecs` | `0` → 关闭 |

乘法模式若启用，公式会变成（`scoring.rs:101-110`）：

```
score = (P(not_dwelled) + offset)^exponent × (Σ正向加权 + engage_bias) × (1 + w·dwell_time)
```

即「不划走的概率」×「互动期望」×「时长因子」三者相乘。目前**未启用**。