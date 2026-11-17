# x-algo-kb

[English](README.md) | **简体中文**

[![License](https://img.shields.io/github/license/youngfreeFJS/x-algo-kb-skill)](LICENSE)
[![Stars](https://img.shields.io/github/stars/youngfreeFJS/x-algo-kb-skill)](https://github.com/youngfreeFJS/x-algo-kb-skill/stargazers)
![Upstream pinned](https://img.shields.io/badge/upstream-a284320b-blue)
![Docs](https://img.shields.io/badge/docs-16%20%C2%B7%20zh%20%2B%20en-green)

直接问 agent「我的帖子为什么没曝光」，它只能猜。x-algo-kb 把这个猜换成生产数值和它出自
哪行代码。它是一份建立在 [`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm)
之上的知识库——X 公开推流代码的那个仓库——覆盖**推流**（排序、召回、冷启动）和
**风控**（打标、可见性丢弃、处置）。

Claude Code、Codex、Cursor、Qoder，以及任何读 [Agent Skills](https://agentskills.io)
格式的 agent 都能用。

> **你问：**我评论了一个大 V，他一直没回我。我是不是被限流了？
>
> **不装它：**有可能。X 会给看起来像垃圾账号的号降低曝光。建议换换措辞、别连着发太多评论，
> 再搜一下自己的帖子还在不在搜索结果里。
>
> **装了它：**不是。观众没关注的作者发的回复，根本进不了 For You 推荐池——
> `EnablePhoenixOonReplies = false`（`home-mixer/params/param.rs:71`）。而大家常拿来背锅的
> 那两个标签 `RISKY_HIGH_VIZ_REPLY` 和 `SPAM_HIGH_RECALL_OON` 只接在通知面
> （`visibility-filtering/rules/levels.rs:253-297`），在 For You 规则块
> （`levels.rs:338-381`）里出现 0 次。

## 安装

需要 Node.js 22.20 或更新。在你的项目里跑：

```bash
npx skills add youngfreeFJS/x-algo-kb-skill
```

按提示选 `x-algo-kb` 和你的 agent。不想走交互就用下面这些：

| Agent | 命令 | 装到哪 |
|---|---|---|
| Claude Code | `npx skills add youngfreeFJS/x-algo-kb-skill --skill x-algo-kb -a claude-code` | `.claude/skills/` |
| Codex | `npx skills add youngfreeFJS/x-algo-kb-skill --skill x-algo-kb -a codex` | `.agents/skills/` |
| Cursor | `npx skills add youngfreeFJS/x-algo-kb-skill --skill x-algo-kb -a cursor` | `.agents/skills/` |
| Qoder | `npx skills add youngfreeFJS/x-algo-kb-skill --skill x-algo-kb -a qoder` | `.qoder/skills/` |

加 `-g` 装到所有项目而不是只装当前项目（`~/.claude/skills/`、`~/.qoder/skills/` 等）。
装完执行 `/skills reload`，或者重启会话。

<details>
<summary>没有 Node，或者 CLI 不认识你的 agent</summary>

```bash
git clone https://github.com/youngfreeFJS/x-algo-kb-skill.git
cd x-algo-kb-skill

ln -s "$(pwd)/skills/x-algo-kb" ~/.qoder/skills/x-algo-kb     # 用户级
ln -s "$(pwd)/skills/x-algo-kb" .claude/skills/x-algo-kb      # 或项目级
```

任何读 `SKILL.md` 加附带文件的运行时都能用。目录结构不绑定某一家：把软链指向你的 agent
的 skills 目录即可。
</details>

```bash
npx skills update x-algo-kb     # 更新到新版
npx skills remove x-algo-kb     # 卸载
```

**然后粘这一句，确认它真的加载了：**

```
What is BidirectionalFollowReplyWeightBoost set to, and which file and line?
```

通过：答案里同时有 `15.0` 和 `param.rs:458`。不通过：只给数值不给 `文件:行号`，或者说自己
不可能知道——说明装上了但没加载，执行 `/skills reload`。

**不想装任何东西？**八篇文档就是普通 Markdown，直接在 GitHub 上读，从
[`08-playbook`](skills/x-algo-kb/references/zh/08-playbook.md) 开始最实用。

## 用法

直接问就行。技能的 description 里带了中英双语触发词（`shadowban`、`deamplification`、
`限流`、`降权`、`推流`、`权重`、`涨粉`、`冷启动`、`风控`），问题跟曝光有关时它自己就会加载。
想强制调用就打 `/x-algo-kb`。

下面五个答案文档里已经有了。你的 agent 会读指名的那一篇，按这个形状回答，给同样的出处。

### 「我的帖子零曝光，从哪查？」

四类互不相同的失败，四个不同的查法，而不是一句含糊的「被限流了」：

| 类别 | 发生了什么 | 查哪里 |
|---|---|---|
| A | 根本没进召回索引 | 索引前置可见性过滤 |
| B | 进了索引，被可见性规则丢弃 | `04-visibility-filtering` |
| C | 排序靠后，或被去重合并进别的帖 | `02` / `03` |
| D | 正常展示，但通知被掐 | `levels.rs:253-297` |

读：[`08-playbook`](skills/x-algo-kb/references/zh/08-playbook.md) §1 和 §3，按顺序走诊断，
并列出那些根本不是限流的正常机制（48 小时窗口、会话去重、作者衰减、已读去重）。

### 「我刚开的新号，实际能拿到什么？」

是扶持，不是打压——而且预算是硬的：

| 门槛 | 生产值 | 出处 |
|---|---|---|
| 必须原创帖（非回复、非转推） | 硬性 | `author_cold_start.rs:189-190` |
| 作者粉丝数 | ≤ 50,000 | `param.rs:709` |
| 帖子发布时长 | ≤ 7200 秒（2 小时） | `param.rs:715` |
| 该帖首页曝光数 | < 200 | `param.rs:691` |
| 每次请求抬升名额 | **1 条** | `author_cold_start.rs:216-226` |
| 抬到第几位 | **第 16 位** | `param.rs:697,703` |

选谁用 Thompson 采样，`Beta(0.75, 49.25)`——先验点赞率 1.5%（`param.rs:741,747`）。
前 200 次曝光就是全部试错预算。

读：[`02-scoring-ranking`](skills/x-algo-kb/references/zh/02-scoring-ranking.md) §4.3、
[`08-playbook`](skills/x-algo-kb/references/zh/08-playbook.md) §4.4。

### 「多去大 V 底下评论能涨粉吗？」

只对一半。评论本身永远不会被推荐给陌生人（`EnablePhoenixOonReplies = false`，
`param.rs:71`）。真正兑现的是它建立的互关：`BidirectionalFollowReplyWeightBoost = 15.0`
（`param.rs:458`）把那位作者**原创帖**上 reply 的权重从 5.0 抬到 20.0，资格条件要求
`!is_reply && !is_retweet`（`xai-value-model/inputs.rs:20-22`）。红利落在你之后的原创帖上，
不落在你为了建立关系去写的那些评论上。

读：[`02-scoring-ranking`](skills/x-algo-kb/references/zh/02-scoring-ranking.md) §3、
[`08-playbook`](skills/x-algo-kb/references/zh/08-playbook.md) §4.2–4.3。

### 「我该盯着点赞优化吗？」

不该。`ContClickDwellTimeWeight` 是**每秒** 0.385（`param.rs:549`）；`FavoriteWeight` 是
0.708 **乘一个预测概率**（`param.rs:451`）。预测停留 10 秒得 3.85 分，点赞概率 0.1 得
0.0708 分。停留时长的贡献比点赞大一到两个数量级。

读：[`02-scoring-ranking`](skills/x-algo-kb/references/zh/02-scoring-ranking.md) §1–2、
[`08-playbook`](skills/x-algo-kb/references/zh/08-playbook.md) §4.1。

### 「我的号是不是有 spam 味？怎么查？」

没有单一的 spam 分数。四层互相独立——行为、账号、内容、回复——只有一个可查入口：
[Under the Hood](https://x.com/i/jf/under_the_hood)。完整答案连同每个阈值和出处，见下面的
[完整示例](#完整示例)。

读：[`06-account-credibility`](skills/x-algo-kb/references/zh/06-account-credibility.md)、
[`05-safety-labeling`](skills/x-algo-kb/references/zh/05-safety-labeling.md)。

### 只问一条规则，不问整个主题

规则名、`SafetyLabelType` 变体、param 名、feature switch key 在两版里都保留英文，
一个 pattern 通吃：

```bash
grep -n "DO_NOT_AMPLIFY\|do_not_amplify" .claude/skills/x-algo-kb/references/zh/04-visibility-filtering.md
```

## 里面有什么

八个主题，中英各一份，内容对等。只读与问题对应的那一篇，按你的语言选，别两边都读。

| 文件 | 覆盖 | zh 字符 | en 字符 |
|---|---|---|---|
| [`01-architecture`](skills/x-algo-kb/references/zh/01-architecture.md) | 两条流水线、29 模块地图、版本锚点、更新时间线 | 7852 | 13947 |
| [`02-scoring-ranking`](skills/x-algo-kb/references/zh/02-scoring-ranking.md) | 生产权重表、加权公式、互关加成、作者衰减、OON 折扣、冷启动 | 9872 | 13989 |
| [`03-retrieval-filtering`](skills/x-algo-kb/references/zh/03-retrieval-filtering.md) | 召回配额、21 道打分前过滤、排序后过滤、会话去重 | 7829 | 12969 |
| [`04-visibility-filtering`](skills/x-algo-kb/references/zh/04-visibility-filtering.md) | severity fold、ALLOW/NOTICE/INTERSTITIAL/DROP、audience 语义、年龄门禁、法律下架 | 50198 | 63125 |
| [`05-safety-labeling`](skills/x-algo-kb/references/zh/05-safety-labeling.md) | botmaker 规则语言、公开规则、处置档位、TTL、申诉 hold | 49729 | 69237 |
| [`06-account-credibility`](skills/x-algo-kb/references/zh/06-account-credibility.md) | PageRank 信誉、agatha 比值、bdsm 行为模型、NSFW 校准曲线 | 39244 | 55652 |
| [`07-models`](skills/x-algo-kb/references/zh/07-models.md) | Phoenix 架构、双塔召回、损失函数、DPP 重排、索引前置风控 | 37494 | 49171 |
| [`08-playbook`](skills/x-algo-kb/references/zh/08-playbook.md) | 可执行打法、误解纠正、限流自查 | 12872 | 24046 |

英文版把 `zh/` 换成 `en/`。体量是实测的，`wc -m` 可复现。

`04`–`07` 是穷举式清单，窄问题先 grep。其中三篇收尾带可单独读的浓缩节：`04` §12 诊断速查、
`05` §12 可直接引用的硬结论、`06` §10 三句话结论。`07` 没有浓缩节。

## 五条会改变你做法的结论

1. **停留时长的贡献比点赞大一到两个数量级。**每秒 0.385 对 0.708 × 预测概率
   （`param.rs:549,451`）。为「读完」写。
2. **你的回复永远不会被推荐给陌生人。**`EnablePhoenixOonReplies = false`（`param.rs:71`）。
   评论建立的是关系，买不到曝光。
3. **互关加成兑现在你之后的原创帖上。**reply 权重加 15.0，且只对非回复非转推的帖子生效
   （`param.rs:458`、`xai-value-model/inputs.rs:20-22`）。
4. **前 200 次曝光就是全部冷启动预算。**每次请求只有 1 条帖子被抬到第 16 位，门槛是
   粉丝 ≤50,000、发布 ≤7200 秒、首页曝光 <200
   （`param.rs:691,697,703,709,715`）。超过 200 就永久退出这个池子。
5. **「spam 味」是算术，不是感觉。**`timing_regularity = 1 / (1 + std(Δt))`，Δt 单位是
   毫秒；`engagement_without_impression` 在一条从未被渲染过的帖子上收到服务端互动动作时
   触发（`bdsm/rust/abuse-v3-features/src/derived.rs:53-57,102-115`）。100 毫秒的间隔抖动
   就把 regularity 压到 0.01 以下。

## 自己核验数值

可选。上面所有内容都不需要上游源码——文档里已经带了数值。想拿 X 自己的代码核对、而不是
信任本仓库时，再跑下面这些。每步都是一条命令加一个字面预期结果，第一个失败就停下。

### 1. 确认装全了

```bash
npx skills list
find -L .claude/skills/x-algo-kb -name '*.md' | wc -l
```

`skills list` 必须打印一行以 `x-algo-kb` 开头、且带
`Source: youngfreeFJS/x-algo-kb-skill`。计数必须正好是 **17**——1 个 `SKILL.md`
加 8 篇中文、8 篇英文。是别的数字就说明装漏了。路径按上面安装表里你的 agent 换，
`-L` 别去掉：默认安装是软链，不加 `-L` 的 `find` 不跟软链。

### 2. 取钉死版本的源码

```bash
bash .claude/skills/x-algo-kb/scripts/fetch-source.sh
```

预期输出——首次 clone 时第一行是 `OK: source ready at pinned commit`，目录已存在时是
`OK: already at pinned commit`：

```
OK: source ready at pinned commit
path: /tmp/x-algorithm
commit: a284320b66a9dce35e6f5d6b052ee308eeb12326
```

commit 不一样，就说明本知识库的引用不适用于你取到的这份代码。目标目录有未提交改动时脚本
拒绝执行。想 clone 到别处就传路径：
`bash .claude/skills/x-algo-kb/scripts/fetch-source.sh ~/src/x`。

### 3. 核四个生产数值

```bash
sed -n '71p;451p;458p;549p' /tmp/x-algorithm/home-mixer/params/param.rs
```

预期输出，一字不差：

```
    false
    0.708
    15.0
    0.385
```

依次是 `EnablePhoenixOonReplies`、`FavoriteWeight`、
`BidirectionalFollowReplyWeightBoost`、`ContClickDwellTimeWeight`——上面第 1、2、3 条结论。

### 4. 核冷启动预算和通知边界

```bash
sed -n '691p;709p;715p' /tmp/x-algorithm/home-mixer/params/param.rs
sed -n '338,381p' /tmp/x-algorithm/visibility-filtering/rules/levels.rs \
  | grep -c 'RISKY_HIGH_VIZ_REPLY\|SPAM_HIGH_RECALL_OON'
```

第一条命令三行分别打印 `200`、`50000`、`7200`。第二条打印 **0**——这两个标签在 For You
推荐规则块里一次都没出现。大家常拿来背锅的那两个标签根本没接到曝光上。

## 八个最容易答错的点

每条都经过源码实证，而且每条都是**即使代码读对了也照样容易答错**的地方。

| # | 坑 | 证据 |
|---|---|---|
| 1 | 权重乘的是预测概率，不是互动计数。「1 举报抵消 468 赞」是错的，当前比值约 330，而且 330 也不能读成计数等价。 | `xai-value-model/scoring.rs:34-44` |
| 2 | 作者多样性衰减与 OON 折扣不在 home-mixer 生效。那里硬编码关闭，真正生效在 vm-ranker。 | `home-mixer/scorers/value_model.rs:46-49`、`vm-ranker/scoring/value_model.rs:109-114` |
| 3 | `vm-ranker/params.rs` 的默认值是旧的：顶部无 sync 戳，`FavoriteWeight` 写 0.5。两者读同一个 feature switch key，生产取同一个值。一律以 `home-mixer/params/param.rs` 为准。 | `param.rs:448-452` |
| 4 | home-mixer 两个「新号」过滤器默认关闭，且「新号」指**观众**，不是作者。 | `param.rs:937-941,967-971`、`new_user_min_engagement_filter.rs:70-77` |
| 5 | 代码存在 ≠ 生产在跑。乘法融合、页面级 RL 探索、MOE 与 SID 召回、库存 holdout 默认全关；权重扰动在 sigma 0 时是空操作。 | `param.rs:189-193,370-374,596-600,845-849,1157-1161`、`weights.rs:145-148` |
| 6 | 排序和可见性是两套独立系统。「限流」是可见性判决或没进索引，不是分数被调低。 | `vf_client.rs:37-38` |
| 7 | 若干垃圾/回复标签掐的是通知，不是 For You 曝光。 | `levels.rs:253-297` |
| 8 | README 里「移除了 X」只指一个模块里的一个组件。巴西的 home-mixer 过滤器已删，visibility-filtering 的规则仍挂着。 | `tweet_rules.rs:951-959` |

## 完整示例

**问题：**我的号是不是有 spam 味？怎么查？

**知识库给出的答案：**

没有单一的 spam 分数。四层互相独立，其中只有一层可查。

**行为层。**bdsm 从你的动作序列里算这些
（`bdsm/rust/abuse-v3-features/src/derived.rs:81-148`；键名在 `lib.rs:602-616`）：

| 信号 | 定义 |
|---|---|
| `timing_regularity` | `1 / (1 + std(Δt))`，Δt 单位毫秒。100 毫秒抖动 → 低于 0.01 |
| `engagement_without_impression` | 服务端动作 id ∈ {1..10, 61, 62, 70} 落在一条此前没有渲染 id ∈ {11, 12} 的帖子上 |
| `action_burst_count` | 序列位置 ±5 之内、且与本次动作间隔 <1000 毫秒的动作数 |
| `target_tweet_repetition` | 同一条帖被互动的最大次数 ÷ 序列长度 |

**账号层。**agatha 比值是对活跃用户做百分位校准的，所以 0.99 就是最差 1%。生产阈值：
`AgathaSpamSuspended > 0.99 || AgathaAllSpamReportsPerFav > 0.999 || AgathaSpamReportsPerFav > 0.999`
→ `AGATHA_SPAM_TOP_USER`，TTL 一周
（`ProductionAgatha__FilterOutOrganicNotifications.bot:18-33`）。高 PageRank、灰标认证、
skiplist 账号豁免。

**内容层。**grox 的 14 种 Spam policyType 里，四种打标且完全没有豁免：
`SpamEngagementBaiting`、`SpamEngagementFarming`、`SpamCardManipulation`、`SpamPromotesShares`。
两种永不打 Spam 标：`SpamPromotesClicks`、`SpamPromotesReplies`。其余全部只在账号不是
高 PageRank 时才打标（`task_write_safety_post_annotations_result_sink.py:233-261`）。

**回复层。**独立的 0–3 rubric。`score == 0.0` 打 `RiskyHighVizReply`，而且新分只在更低时
才覆盖旧分——回复分单调不增（`grox/flows/reply_spam/task_write.py:127-141`）。

**怎么查。**打开 [Under the Hood](https://x.com/i/jf/under_the_hood)。它显示你账号和帖子上
实际被打了哪些标签、是否有人工标签绕过了自动系统、以及某条帖是否因法律要求在某国被隐藏。
它不暴露 agatha 和 bdsm 的模型分数。bdsm 的处置阈值是被涂掉的：`sink_policy.yaml:5-15`
把它们换成了 `9.99` 哨兵值和 `999999` 计数闸门。处置服务 YAML 里的 `12.34` 和 `12345.67`
是注释明说的 mock 值。任何「分数超过 X 就封号」的公开数字都是编的。

## 它是怎么工作的

X 每次请求现场拼 For You，来源两路：观众关注的账号发的站内帖，和 ML 召回的站外帖。
一个 transformer 模型 Phoenix 给每个候选预测各动作的概率，再用
`home-mixer/params/param.rs` 里的权重混成一个分数。

之后有两套系统作用于这个分数，而且彼此独立。**排序**决定顺序。**可见性过滤**决定这条帖
到底能不能被展示，依据是观众的拉黑屏蔽关系，以及 botmaker、grox、agatha、bdsm 和媒体模型
打上的标签。一条帖可以分数很高、排到第三，然后被丢弃。

所以「限流」这个框架本身是错的。降权是**推荐资格被布尔剥夺**，不是分数被调低。
信誉标签的 drop 规则挂在 `TimelineHomeRecommendations`（thrift 61）；`TimelineHome`
（thrift 8）没有这类规则（`vf_client.rs:37-38`）。诊断要读标签，不是读分数。

16 篇文档之间做了机器校验：8 个主题，中英两版的标题数、表格行数、引用集合逐项相等。
x-algo-kb 不是 fork，仓库里不内嵌上游源码。上游故意没公开的东西，文档里写**「未公开」**，
到此为止。

## 出处

- [`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm)，Apache-2.0，钉在
  `a284320b66a9dce35e6f5d6b052ee308eeb12326`（2026-11-17T03:20:50Z）。
- 参数基线：`home-mixer/params/param.rs:1` 的 sync 戳 → `2026-11-16T16:00:37Z`。
- [Under the Hood](https://x.com/i/jf/under_the_hood) 是 X 自己的标签透明度工具，
  serving 代码在 `under-the-hood/`。

所有引用相对该 commit 的上游根目录，上游持续更新后会漂移。把某个行号当「现状」引用前，
先用 `scripts/fetch-source.sh` 重新取一次源码。

## 许可

Apache-2.0。见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。

与 xAI 或 X Corp 无关联、未获其背书或赞助。「X」与「Twitter」是各自所有者的商标，
此处仅用于指明文档主题。

如果 x-algo-kb 帮你避开了一个错误答案，点个 star 能让更多人找到它。
