# x-algo-kb

[English](README.md) | **简体中文**

[![License](https://img.shields.io/github/license/youngfreeFJS/x-algo-kb-skill)](LICENSE)
[![Stars](https://img.shields.io/github/stars/youngfreeFJS/x-algo-kb-skill)](https://github.com/youngfreeFJS/x-algo-kb-skill/stargazers)
![Upstream pinned](https://img.shields.io/badge/upstream-a284320b-blue)
![Docs](https://img.shields.io/badge/docs-16%20%C2%B7%20zh%20%2B%20en-green)

一份能装进 agent 的 X For You 算法知识库。同时覆盖**推流**（帖子怎么被排序和下发）和
**风控**（帖子怎么被打标、限制、丢弃），每条结论都带 `文件:行号` 出处，指向
[`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm)。

Claude Code、Codex、Cursor、Qoder，以及任何读
[Agent Skills](https://agentskills.io) 格式的 agent 都能用。

---

不装这个问 X 曝光，你拿到的是听着挺合理的建议。装了之后拿到的是机制、生产数值，
以及它是从哪行代码读出来的。

> **问题：**我评论了一个大 V，他一直没回我。我是不是被限流了？

**没有知识库**——听着像那么回事，但把你带错方向：

> 有可能。X 会给看起来像垃圾账号的号降权。建议换换措辞、别连着发太多评论，
> 再搜一下自己的帖子还在不在搜索结果里。

**有知识库**——这个问题把两套独立系统混为一谈了：

> 不是。两个独立原因，都跟曝光降权无关：
>
> 1. 观众没关注的作者发的回复，**根本进不了 For You 推荐池**——
>    `EnablePhoenixOonReplies = false`（`home-mixer/params/param.rs:71`）。
>    你那条评论的可见范围本来就只有已经关注你的人，和点进这条线程的人。
> 2. 大家通常拿来背锅的那几个标签——`RISKY_HIGH_VIZ_REPLY`、`SPAM_HIGH_RECALL_OON`、
>    `LOW_QUALITY_AND_UQF_DROPS`——**只接在通知面**
>    （`visibility-filtering/rules/levels.rs:253-297`），从未挂到
>    `TIMELINE_HOME_RECOMMENDATIONS`。它们能掐掉一条通知，掐不掉你的曝光。

**这不是什么。**不是 fork，仓库里不内嵌上游源码。与 xAI / X Corp 无任何关联。
所有行号钉在一个 commit 上，上游持续更新后会漂移。上游故意没公开的东西，
文档里写**「未公开」**，不猜。

## 快速开始

安装器需要 Node.js 22.20+。

```bash
npx skills add youngfreeFJS/x-algo-kb-skill
```

按提示选你的 agent。加 `-g` 装到所有项目，不加只装当前项目。免交互写法：

```bash
npx skills add youngfreeFJS/x-algo-kb-skill --skill x-algo-kb -a claude-code -g
```

<details>
<summary>手动安装，或 CLI 不认识的 agent</summary>

```bash
git clone https://github.com/youngfreeFJS/x-algo-kb-skill.git
cd x-algo-kb-skill

# 用户级
ln -s "$(pwd)/skills/x-algo-kb" ~/.qoder/skills/x-algo-kb
# 或项目级
ln -s "$(pwd)/skills/x-algo-kb" /path/to/project/.qoder/skills/x-algo-kb
```

Claude Code 用 `~/.claude/skills/`，Codex 用 `~/.codex/skills/`。任何读
`SKILL.md` + 附带资源的运行时都能用，目录结构不绑定 Qoder。
</details>

然后 `/skills reload`，或者重启会话。用 `/x-algo-kb` 直接调，也可以直接问——
description 里带了中英双语触发词（`shadowban`、`deamplification`、`限流`、`降权`、
`推流`、`权重`、`涨粉`、`冷启动`、`风控`）。

## 拿这四个问题试

每个都是一次有效测试：**答案里没有数值和出处，就说明技能没被读进去。**
下面列出期望内容，方便你对照。

### 1.「互关到底给我加多少？」

期望：`BidirectionalFollowReplyWeightBoost = 15.0`（`param.rs:458`），
把互关作者**原创帖**上的 reply 权重从 5.0 抬到 20.0，翻 4 倍。
资格条件是 `!is_reply && !is_retweet && is_mutual_follow_author`
（`xai-value-model/inputs.rs:20-22`）。

红利落在你**之后的原创帖**上，不落在你为了建立关系去写的那些评论上。
这个区别正是「多去大 V 底下评论」这类建议只对一半的原因。

### 2.「新号实际能拿到什么？」

期望是**扶持**，不是打压——而且预算是硬的：

| 门槛 | 生产值 | 出处 |
|---|---|---|
| 必须原创帖（非回复、非转推） | 硬性 | `author_cold_start.rs:189-190` |
| 作者粉丝数 | ≤ 50,000 | `param.rs:709` |
| 帖子发布时长 | ≤ 7200 秒（2 小时） | `param.rs:715` |
| 该帖首页曝光数 | < 200 | `param.rs:691` |
| 每次请求抬升名额 | **1 条** | `author_cold_start.rs:216-226` |
| 抬到第几位 | **第 16 位** | `param.rs:697,703` |

选谁用 Thompson 采样，`Beta(0.75, 49.25)`——先验点赞率 1.5%
（`param.rs:741,747`）。**前 200 次曝光就是全部试错预算**，超过就永久退出冷启动池。

### 3.「我该盯着点赞优化吗？」

期望：不该。`click_dwell_time` 是**每秒 0.385**（`param.rs:549`），
而 `favorite` 是 **0.708 × 预测概率**（`param.rs:451`）。
预测停留 10 秒 = 3.85 分，点赞概率 0.1 = 0.0708 分。
**停留时长的贡献比点赞大一到两个数量级**，是当前算法里最被低估的一项。

2026 年 10 月上游两次更新都在往时长上加码：先是排序模型改进停留时长预测（10 月 8 日），
然后召回模型也被训练去 surface 那些「读完」的帖子（10 月 13 日）。

### 4.「我的帖子零曝光，该从哪查？」

期望是四类互不相同的失败，而不是一句含糊的「被限流了」：

| 类别 | 发生了什么 | 查哪里 |
|---|---|---|
| **A** | 根本没进召回索引 | 索引前置可见性过滤 |
| **B** | 进了索引，被可见性规则丢弃 | `04-visibility-filtering` |
| **C** | 排序靠后，或被去重合并进别的帖 | `02` / `03` |
| **D** | 正常展示，但通知被掐 | `levels.rs:253-297` |

诊断要查标签，不是查分数。信誉标签 drop 规则挂在
`TimelineHomeRecommendations`（thrift **61**），`TimelineHome`（thrift **8**）没有这类规则
（`vf_client.rs:37-38`）。限流是**推荐资格被布尔剥夺**，不是分数被调低。

## 里面有什么

八个主题，中英各一份，内容对等。**只读**与问题对应的那一篇，按你的语言选。

| 文件 | 覆盖 | 体量 zh/en 字符 |
|---|---|---|
| [`01-architecture`](skills/x-algo-kb/references/zh/01-architecture.md) | 两条流水线、29 模块地图、版本锚点、更新时间线 | 8k / 14k |
| [`02-scoring-ranking`](skills/x-algo-kb/references/zh/02-scoring-ranking.md) | 生产权重表、加权公式、互关加成、作者衰减、OON 折扣、冷启动 | 10k / 14k |
| [`03-retrieval-filtering`](skills/x-algo-kb/references/zh/03-retrieval-filtering.md) | 召回配额、21 道打分前过滤、排序后过滤、会话去重 | 8k / 13k |
| [`04-visibility-filtering`](skills/x-algo-kb/references/zh/04-visibility-filtering.md) | severity fold、ALLOW/NOTICE/INTERSTITIAL/DROP、audience 语义、年龄门禁、法律下架 | **50k / 63k** |
| [`05-safety-labeling`](skills/x-algo-kb/references/zh/05-safety-labeling.md) | botmaker 规则语言、公开规则、处置档位、TTL、申诉 hold | **50k / 69k** |
| [`06-account-credibility`](skills/x-algo-kb/references/zh/06-account-credibility.md) | PageRank 信誉、agatha 比值、bdsm 行为模型、NSFW 校准曲线 | **39k / 56k** |
| [`07-models`](skills/x-algo-kb/references/zh/07-models.md) | Phoenix 架构、双塔召回、损失函数、DPP 重排、索引前置风控 | **37k / 49k** |
| [`08-playbook`](skills/x-algo-kb/references/zh/08-playbook.md) | 可执行打法、误解纠正、限流自查 | 13k / 24k |

英文版把 `zh/` 换成 `en/`。

**`04`–`07` 是穷举式清单**——整篇读一次中文约 30–40k token、英文约 13–18k。
窄问题先 grep 标识符，只读命中处上下文。规则名、`SafetyLabelType` 变体、param 名、
feature switch key 在两版里都保留英文，一个 pattern 通吃：

```bash
grep -n "DO_NOT_AMPLIFY\|do_not_amplify" skills/x-algo-kb/references/zh/04-visibility-filtering.md
```

四篇里有三篇收尾带可单独读的浓缩节：`04` §12 诊断速查、`05` §12 可直接引用的硬结论、
`06` §10 三句话结论。`07` 没有浓缩节。运营类问题从 `08-playbook` 进，最便宜。

## 八个最容易答错的点

这些就是本知识库要防的错误。每条都经过源码实证，而且每条都是
**即使代码读对了也照样容易答错**的地方。

1. **权重乘的是预测概率，不是互动计数。**「1 举报抵消 468 赞」是错的，上游专门写注释纠正
   （`xai-value-model/scoring.rs:34-44`）。当前比值约 330，**但即使 330 也不能读成计数等价**。
2. **作者多样性衰减与 OON 折扣不在 home-mixer 生效。**那里硬编码 false
   （`home-mixer/scorers/value_model.rs:46-49`），真正生效在 vm-ranker
   （`vm-ranker/scoring/value_model.rs:109-114`）。
3. **`vm-ranker/params.rs` 的权重默认值是旧的。**顶部无 sync 注释，`FavoriteWeight` 写 0.5，
   而 home-mixer 是 0.708。两者读同一个 feature switch key，生产取同一个值。
   **一律以 `home-mixer/params/param.rs` 为准。**
4. **home-mixer 两个「新号」过滤器默认关闭，且「新号」指观众。**
   `param.rs:937-941,967-971`；年龄判定用 `query.user_id`
   （`new_user_min_engagement_filter.rs:70-77`）。不是新作者的门槛。
5. **代码存在 ≠ 生产在跑。**乘法融合、页面级 RL 探索、MOE 与 SID 召回、库存 holdout
   默认全关（`param.rs:189-193,370-374,596-600,845-849,1157-1161`）；
   权重扰动在 sigma 0 时是空操作（`weights.rs:145-148`）。
6. **排序和可见性是两套独立系统。**「限流」通常是可见性判决或没进索引，不是分数被调低。
7. **若干垃圾/回复标签掐的是通知，不是 For You 曝光。**`levels.rs:253-297`。
   「我评论了他没理我」不等于被限流。
8. **README 里「移除了 X」只指一个模块里的一个组件。**巴西选举过滤器是两层：
   home-mixer 那份已删，visibility-filtering 的 `brazil_election_legal/drop/undesirable`
   仍挂在 `RequestCountryIs("br")` 下（`tweet_rules.rs:951-959`）。

## 怎么保证不瞎说

- **钉死一个 commit。**所有引用相对上游根目录，基准
  `a284320b66a9dce35e6f5d6b052ee308eeb12326`（2026-11-17T03:20:50Z）；
  参数基线是 `home-mixer/params/param.rs:1` 的 sync 戳 → `2026-11-16T16:00:37Z`。
- **取生产默认值，不取实验值。**文档区分「已验证的生产默认」「代码在但默认关」「未公开」，
  只要影响结论就明说是哪一种。
- **「未公开」是个正经答案。**Grox 的 LLM prompt、部分 botmaker 规则、
  以及被换成哨兵值或 mock 的一些策略阈值，都标为未公开，不推断。
  处置服务里的 `12.34` 和 `12345.67` 是官方 mock，不是阈值。
- **双语对等是机器校验的。**八个主题的标题数、表格行数、引用集合在 `zh/` 和 `en/` 之间逐项相等。

想自己核任何一条出处：

```bash
bash skills/x-algo-kb/scripts/fetch-source.sh          # clone 到 /tmp/x-algorithm
bash skills/x-algo-kb/scripts/fetch-source.sh ~/src/x  # 或指定目录
```

脚本会钉到那个 commit，且目标目录有未提交改动时拒绝执行，不会覆盖你的工作。

## 许可与署名

Apache-2.0。见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。

派生自 [`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm)，同为 Apache-2.0。
本项目**与 xAI 或 X Corp 无关联、未获其背书或赞助**。「X」与「Twitter」是各自所有者的商标，
此处仅用于指明文档主题。
