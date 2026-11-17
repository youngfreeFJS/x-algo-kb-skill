# 01 · 总览：X For You 信息流的两条流水线

> 来源：[xai-org/x-algorithm](https://github.com/xai-org/x-algorithm)，Apache 2.0
> 代码规模：约 29MB，700 个 `.rs` + 568 个 `.scala` + 489 个 `.py` + 313 个 `.java`
> 参数同步时间：`home-mixer/params/param.rs:1` → `2026-11-16T16:00:37Z`

## 版本锚点与复核方法

本知识库所有行号引用基于以下版本，**复核前先对齐版本**，否则行号会错位：

| 项 | 值 |
|---|---|
| 仓库 | `https://github.com/xai-org/x-algorithm` |
| commit | `a284320b66a9dce35e6f5d6b052ee308eeb12326` |
| 提交时间 | `2026-11-17T03:20:50Z` |

重新取得同一版本：

```bash
git clone https://github.com/xai-org/x-algorithm.git /tmp/x-algorithm
cd /tmp/x-algorithm && git checkout a284320b66a9dce35e6f5d6b052ee308eeb12326
```

本文档中的路径均相对仓库根，例如 `home-mixer/params/param.rs:451` 对应
`/tmp/x-algorithm/home-mixer/params/param.rs` 第 451 行。

**注意**：上游会持续更新（README 的 Notable Updates 就是变更记录）。如果 `git log` 显示有新提交，
优先看 `home-mixer/params/param.rs` 的 diff——权重和阈值变化都在那里，
`docs/BIDIRECTIONAL_BOOST_CHANGE.md` 是官方给的变更范例。

---

## 1. 最核心的一句话

**X 的推荐系统由两套完全独立的系统组成：**

| | 排序（Ranking） | 可见性（Visibility） |
|---|---|---|
| 决定 | 一条帖**排第几** | 一条帖**能不能给你看** |
| 服务 | `phoenix/` + `vm-ranker/` | `visibility-filtering/` |
| 输入 | 你的行为序列 + 帖子特征 | 账号/帖子上的安全标签 + 你和作者的关系 + 你的设置/国家 |
| 输出 | 一个分数 | ALLOW / NOTICE / INTERSTITIAL / DROP |

README `Key Design Decisions` 第 4 条原文：

> Ranking decides the order. Visibility filtering decides whether a post can be shown at all. Different services, different inputs, different rules.

**这是理解「限流」的关键**：所谓被限流，绝大多数情况不是「分数被调低」，而是**在可见性层被判 DROP 或降级**，或者**根本没进召回索引**。两套系统的诊断方式完全不同。

---

## 2. 请求路径（一条 For You 请求发生了什么）

```
FOR YOU 请求
    │
    ▼  home-mixer/  ── POST PIPELINE (PhoenixCandidatePipeline)
    │
    ├─ 1. 查询 hydration ── home-mixer/query_hydrators/
    │     你的近期互动序列（模型主输入）、关注列表、拉黑/屏蔽、
    │     屏蔽关键词、已读/已下发、关注话题、地理、设备、性别推断…
    │
    ├─ 2. 候选召回（并行）── home-mixer/sources/
    │     关注内：Thunder（内存实时池，1200 条）
    │     关注外：Phoenix 双塔检索（1000）+ 冷启动（200）
    │             SimClusters（社区聚类）+ Popular posts（500）
    │
    ├─ 3. 候选 hydration ── home-mixer/candidate_hydrators/
    │     正文/媒体、作者信息与账号标签、被引用帖、语言、
    │     互动计数、订阅状态、互关判定、VF 标签…
    │
    ├─ 4. 打分前过滤（21 道）── home-mixer/filters/
    │     48 小时、陌生人的回复/转推、已读、屏蔽、订阅…
    │
    ├─ 5. 打分
    │     PhoenixScorer  → 每个动作一个概率
    │     RankingScorer  → 加权求和
    │     VMRanker       → 调 vm-ranker/ 重算 + DPP 重排
    │
    ├─ 6. 选择 ── TopKScoreSelector（按分排序取 top K）
    │
    └─ 7. 排序后过滤 ── VFFilter / AncillaryVFFilter / DedupConversationFilter
          ◄── 标签来自「打标路径」
    │
    ▼  BLENDING PIPELINE (ForYouCandidatePipeline)
    │
    ├─ BlenderSelector 混入非帖内容：广告、Who to Follow、prompts、push-to-home
    │  默认广告混排器：slot_spread（param.rs:1052）
    │
    └─ SIDE EFFECTS（响应发出后）── 记录已下发、刷新缓存、埋点
    │
    ▼
最终 For You 时间线
```

---

## 3. 打标路径（风控，不在请求路径上，持续运行）

```
1. 内容理解（发帖时 / 离线批跑）
   帖子与媒体                          账号
   ├─ grox/            文本+媒体分类器   ├─ agatha/       他人对你帖子的反应
   ├─ media-model-proxy/ 图像视频模型   │                （拉黑/举报/垃圾举报 ÷ 点赞）
   └─ clip/            图文 embedding   ├─ bdsm/         行为序列 → 非真实行为
                                       └─ user-cred-v2/ 关注图+互动图 PageRank
    │
    ▼
2. 打标规则
   ├─ scarecrow/         事件驱动。内嵌 botmaker/ 作规则引擎，
   │                     规则来自 botmaker-rules/scarecrow/
   │                     规则形式：on 事件, if 条件, apply 标签
   ├─ abuse-enforcement-service/  基于模型分数（非事件）：
   │                     打标 / 挑战验证 / 封号
   │                     申诉推翻的处置不再重复施加（abuse-ledger-service/）
   └─ safety-label-user-agg/      帖子标签聚合成账号标签
    │
    ▼
3. 落库（请求路径回读）
    │
    ▼
4. visibility-filtering/  逐帖 × 逐观众判定
   ALLOW        正常展示
   NOTICE       展示 + 附加提示
   INTERSTITIAL 展示在可点击穿透的遮罩后（成人/血腥媒体）
   DROP         不展示
    │
    ▼
5. home-mixer/filters/vf_filter.rs + ancillary_vf_filter.rs
   DROP → 排序后移除；祖先/被引用/被转推帖被 DROP → 本帖连带移除
   INTERSTITIAL / NOTICE → 帖子留在 feed 里（遮罩和提示由客户端绘制，不在本仓库）
```

---

## 4. 模块地图（29 个顶层目录）

### 4.1 请求路径

| 目录 | 语言 | 职责 |
|---|---|---|
| `home-mixer/` | Rust | For You 组装：流水线、权重、调用下游 |
| `candidate-pipeline/` | Rust | 流水线框架：source / hydrator / filter / scorer / selector / side effect |
| `thunder/` | Scala | 关注内实时内存帖池 |
| `phoenix/` | Python(JAX) + Rust | 召回双塔 + 排序 transformer，训练与 serving |
| `phoenix-rankall/` | Scala | 召回索引维护 |
| `phoenix-rankall-strato/` | Strato | 决定帖进哪个索引，**先咨询 visibility filtering** |
| `simclusters/` | Scala | 社区聚类召回 |
| `vm-ranker/` | Rust | DPP 多样性重排 + 价值模型重算 |
| `xai-value-model/` | Rust | 加权融合公式与权重结构 |

### 4.2 内容理解

| 目录 | 职责 |
|---|---|
| `grox/` | 发帖时跑的文本/媒体分类器（LLM prompt 的 j2 文件**未公开**） |
| `media-model-proxy/` | 图像视频模型服务：成人、暴力血腥、仇恨符号、主题、已知素材匹配 |
| `clip/` | 图文 embedding 模型训练 |
| `adult-content/` | 成人媒体分类器训练与校准 |
| `pnsfwmedia/` | 融合 CLIP embedding + 账号分数（含 agatha 校准分）的成人分类器 |
| `agatha/` | 离线批：他人反应比值 → 账号标签 |
| `bdsm/` | 行为序列 → 非真实/滥用行为分数 |
| `user-cred-v2/` | 关注图 + 互动图 PageRank → 账号信誉分 |

### 4.3 风控与可见性

| 目录 | 职责 |
|---|---|
| `visibility-filtering/` | 逐帖逐观众判定，规则在 `rules/` |
| `visibility-filtering-client/` | 客户端 + 安全标签类型定义 |
| `botmaker/` | 规则引擎：语言、编译器、运行时 |
| `botmaker-rules/` | scarecrow 加载的规则（**部分规则未公开**） |
| `scarecrow/` | 事件驱动打标服务 |
| `abuse-enforcement-service/` | 基于模型分数的处置 |
| `abuse-ledger-service/` | 申诉豁免期 |
| `safety-label-source/` | 标签来源与存储 |
| `safety-label-user-agg/` | 帖标签 → 账号标签聚合 |
| `takedowns/` | 法律下架理由清单 |
| `under-the-hood/` | 透明度报告：账号/帖子上的限流标签统计 |

---

## 5. 仓库里明确「没有」的东西

README `What's not in this repo?` 承认，为降低被绕过风险，以下未公开：

- **Grox 的 LLM prompt**（具体 j2 文件）
- **部分 botmaker 规则**

补偿手段是 [Under the Hood](https://x.com/i/jf/under_the_hood) 透明度工具：能看到自己账号和帖子上实际被打了哪些影响可见性的标签，包括**是否有绕过自动系统的人工标签**，以及**因法律要求在某国被隐藏**（2026-09-18 更新）。

另外，部署相关文件（构建、基础设施 import 如 `xai_service_runner` / `xai_kafka`）大多不在仓库里。只有 `phoenix/` 是设计成可端到端跑通的（含 Cargo workspace、`pyproject.toml`、`QUICKSTART.md`、合成数据生成）。

---

## 6. 值得记住的更新时间线

| 日期 | 变更 | 意义 |
|---|---|---|
| 2026-07-13 → 07-24 | 互关回复加成 20 → **15** | 世界杯期间用户抱怨看不到关注外讨论，主动回调 |
| 2026-08-13 | 首次公开权重、可见性过滤、Phoenix 训练代码、SimClusters | 透明度大版本 |
| 2026-08-14 | 加权注释澄清 + 巴西选举过滤器 | 澄清「1 举报 = 468 赞」误读 |
| 2026-09-18 | Under the Hood 增加法律合规限流信息 | 能看到被哪个国家屏蔽 |
| 2026-10-08 | 排序模型改进停留时长预测 | `phoenix/xrex/models/loss_recsys.py` |
| 2026-10-13 | 召回模型也训练去 surface「读完」的帖 | `recsys_two_tower_model.py` |
| 2026-10-26 | 移除 home-mixer 的 `Brazil2026ElectionFilter` | 选举结束；**VF 侧同名标签规则仍在**，见下 |
| 2026-11-16 | 参数同步（本知识库数值基准） | |

**趋势很明显：从「互动计数」转向「注意力时长 / 读完率」。** 2026 年 10 月两次更新都在强化时长建模。

**巴西选举过滤器是两层，别当成一件事**：上游 10-26 移除的是 **home-mixer 的
`Brazil2026ElectionFilter`**（本 commit 下 `home-mixer/` 内已 grep 不到）。
但 **visibility-filtering 的 `brazil_election_legal/drop/undesirable` 仍然接线**
（`tweet_rules.rs:951-959`，`OON_POST_DROPS` 成员 `levels.rs:215-220`），
条件是 `TweetHasLabel(BRAZIL_ELECTION_LEGAL) && RequestCountryIs("br")`，audience `NonAuthors`。
前者是排序侧的账号名单过滤，后者是可见性侧的法律标签规则，**删掉前者不等于后者失效**。
详见 `04-visibility-filtering` §3.4、§4。

---

## 7. 本知识库导航

| 文档 | 内容 |
|---|---|
| `01-architecture` | 本文：架构、模块地图、更新时间线 |
| `02-scoring-ranking` | 完整权重表、加权公式、互关加成、作者降权、OON 折扣、冷启动 |
| `03-retrieval-filtering` | 召回配额、21 道打分前过滤、排序后过滤、会话去重 |
| `04-visibility-filtering` | ALLOW/NOTICE/INTERSTITIAL/DROP 全规则、OON-only 规则、法律下架 |
| `05-safety-labeling` | botmaker 规则语言、公开规则逐条、处置档位、申诉豁免 |
| `06-account-credibility` | PageRank 信誉、agatha 比值公式、bdsm 行为特征、成人内容判定 |
| `07-models` | Phoenix 架构、双塔、损失函数、DPP、索引前置风控 |
| `08-playbook` | 可执行结论、常见误解纠正、限流自查路径 |

---

## 8. 读这个仓库最容易踩的五个坑

1. **权重 ≠ 计数倍数**。乘的是预测概率。`scoring.rs:34-44` 专门写了注释纠正。
2. **README 说三个乘法调整在 RankingScorer，实际在 vm-ranker**。`home-mixer/scorers/value_model.rs:46-49` 把作者多样性硬编码成 false，真正生效在 `vm-ranker/scoring/value_model.rs:109-114`。
3. **`vm-ranker/params.rs` 的默认值是旧的**（顶部无 sync 注释，FavoriteWeight 写 0.5）。它和 home-mixer 读同一个 feature switch key，生产值以 `home-mixer/params/param.rs`（已同步）为准。
4. **`NewUserMinEngagementFilter` 里的「新用户」是观众不是作者**（`new_user_min_engagement_filter.rs:74` 用的是 `query.user_id`）。
5. **大量能力默认关闭**：乘法融合、权重扰动、页面 RL 探索、库存扣留、新用户 OON 归零、MOE 召回、SID 召回。读到代码 ≠ 线上在跑。