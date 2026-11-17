# x-algo-kb

**An evidence-backed, bilingual knowledge base of X's For You feed algorithm — packaged as an installable Agent Skill.**

Every claim carries a `path:line` citation pinned to one upstream commit. Numbers are
production defaults read from source, not guesses. Where upstream deliberately withheld
something, the docs say **"not public"** instead of inferring a mechanism.

[中文说明](#中文说明) · [English](#english)

---

## English

### What this is

A derivative summary of [`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm)
(Apache-2.0), covering both **distribution** (how posts get ranked and served) and
**risk control** (how posts get labelled, restricted, or dropped).

It is not a fork. No upstream source tree is vendored here. The reference documents quote
short excerpts and reproduce parameter defaults, each attributed to a file and line.

### Why it exists

The upstream repo is ~29MB with 2200+ source files across Rust, Scala, Python and Java.
Reading it end to end to answer one question is expensive, and the answers are easy to get
subtly wrong. This KB does that reading once and writes the conclusions down with citations.

### Source version anchor

| Item | Value |
|---|---|
| Upstream | `https://github.com/xai-org/x-algorithm` |
| Pinned commit | `a284320b66a9dce35e6f5d6b052ee308eeb12326` |
| Commit date | `2026-11-17T03:20:50Z` |
| Param sync stamp | `home-mixer/params/param.rs:1` → `2026-11-16T16:00:37Z` |

All `path:line` citations are relative to the upstream repo root and valid **only at this
commit**. Upstream ships ongoing changes — re-verify before quoting a line number as current.

To retrieve the exact source version:

```bash
bash skills/x-algo-kb/scripts/fetch-source.sh          # clones into /tmp/x-algorithm
bash skills/x-algo-kb/scripts/fetch-source.sh ~/src/x  # or a directory you choose
```

The script refuses to run if the target directory has uncommitted changes, so it will not
overwrite your work.

### Install

The skill lives at `skills/x-algo-kb/`. Install it by copying or symlinking that directory
into your agent's skills directory:

```bash
# user-level (available in every project)
ln -s "$(pwd)/skills/x-algo-kb" ~/.qoder/skills/x-algo-kb

# or project-level
ln -s "$(pwd)/skills/x-algo-kb" /path/to/project/.qoder/skills/x-algo-kb
```

Then reload skills (`/skills reload`) or restart the session. Invoke with `/x-algo-kb`, or
let it trigger automatically — the description carries both English and Chinese trigger
terms (`shadowban`, `deamplification`, `限流`, `降权`, `推流`, `权重`, `涨粉`, `冷启动`, `风控`).

Any agent runtime that reads the Agent Skills format (`SKILL.md` + bundled resources) can
use it; the layout is not Qoder-specific.

### Topics

Read **only** the file matching your question. Each is self-contained. Pick `zh/` or `en/`
by language — the content is equivalent, do not read both.

| File | Covers |
|---|---|
| `01-architecture` | Two pipelines, 29-module map, version anchor, update timeline, reading traps |
| `02-scoring-ranking` | Full production weight table, scoring formula, mutual-follow boost, author decay, OON discount, cold start |
| `03-retrieval-filtering` | Retrieval quotas, 21 pre-scoring filters, post-ranking filters, conversation dedup |
| `04-visibility-filtering` | Severity fold, ALLOW/NOTICE/INTERSTITIAL/DROP, audience semantics, age gating, legal takedowns |
| `05-safety-labeling` | botmaker rule language, public rules, enforcement tiers, TTLs, appeal hold |
| `06-account-credibility` | PageRank credibility, agatha ratios, bdsm behaviour model, NSFW calibration curves |
| `07-models` | Phoenix architecture, two-tower retrieval, loss functions, DPP reranking, index-time VF |
| `08-playbook` | Actionable tactics, myth-busting, shadowban self-diagnosis |

Files live at `skills/x-algo-kb/references/{zh,en}/<name>.md`.

### Six traps that cause wrong answers

These are the errors this KB was built to prevent. Each was verified against source.

1. **Weights multiply predicted probabilities, not engagement counts.**
   "One report cancels 468 likes" is wrong. Upstream wrote comments specifically to correct
   it (`xai-value-model/scoring.rs:34-44`). The current ratio is ≈330, and even that is not
   a count equivalence.

2. **Author diversity decay and the OON discount do not run in home-mixer.**
   They are hardcoded off there (`home-mixer/scorers/value_model.rs:46-49`) and actually
   applied in vm-ranker (`vm-ranker/scoring/value_model.rs:109-114`).

3. **`vm-ranker/params.rs` weight defaults are stale.**
   No sync stamp; `FavoriteWeight` reads 0.5 while home-mixer reads 0.708
   (`param.rs:448-452`). Both read the same feature-switch key. Treat
   `home-mixer/params/param.rs` as authoritative.

4. **Both home-mixer "new user" filters are disabled by default, and "new user" means the
   viewer.** `EnableNewUserMinEngagementFilter` and `EnableNewUserSoftNsfwFilter` are both
   `false` (`param.rs:937-941,967-971`), and the age check uses `query.user_id` — the viewer,
   not the author (`new_user_min_engagement_filter.rs:70-77`). They are not a gate on new
   authors. A new account's real algorithmic treatment is the cold-start **boost**.

5. **Several spam/reply labels suppress notifications, not For You reach.**
   `RISKY_HIGH_VIZ_REPLY`, `SPAM_HIGH_RECALL_OON`, `LOW_QUALITY_AND_UQF_DROPS` and
   `COMMUNITY_AND_SPAM_DROPS` are wired only into notification surfaces
   (`visibility-filtering/rules/levels.rs:253-297`), never into
   `TIMELINE_HOME_RECOMMENDATIONS`. "They never replied to my comment" is not a shadowban.

6. **Ranking and visibility are separate systems.**
   "Deamplification" is usually a **boolean revocation of recommendation eligibility** —
   reputation-label drop rules attach to `TimelineHomeRecommendations` (thrift 61) while
   `TimelineHome` (thrift 8) has none — or exclusion from the retrieval index. It is not a
   lowered score. Diagnose by reading labels, not scores.

### Answering discipline

The skill instructs agents to:

- Distinguish **verified production default** from **code present but disabled** from
  **not public**, and say which one when it changes the conclusion.
- Never extrapolate weight ratios into engagement-count equivalences.
- Say "not public" for withheld material (Grox LLM prompts, some botmaker rules, several
  policy YAML thresholds replaced with sentinel or mock values) rather than inferring.
- Separate what the code supports from what is merely plausible when giving growth advice.

### License and attribution

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

This project is **not affiliated with, endorsed by, or sponsored by xAI or X Corp.**
"X" and "Twitter" are trademarks of their respective owners, used only to identify the
subject of the documentation.

---

## 中文说明

### 这是什么

[`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm)（Apache-2.0）的**双语派生知识库**，
同时覆盖**推流**（帖子怎么被排序和下发）和**风控**（帖子怎么被打标、限制、丢弃）。

不是 fork，仓库里**不内嵌上游源码树**。参考文档引用少量代码片段并复现参数默认值，
每条都带 `文件:行号` 出处。

### 为什么做这个

上游约 29MB、2200+ 源文件，横跨 Rust / Scala / Python / Java。
为回答一个问题通读一遍成本极高，而且极容易答错细节。
本知识库把这次通读做一遍，把结论带证据落盘。

### 版本锚点

| 项 | 值 |
|---|---|
| 上游 | `https://github.com/xai-org/x-algorithm` |
| pinned commit | `a284320b66a9dce35e6f5d6b052ee308eeb12326` |
| 提交时间 | `2026-11-17T03:20:50Z` |
| 参数同步时间 | `home-mixer/params/param.rs:1` → `2026-11-16T16:00:37Z` |

所有 `文件:行号` 相对上游仓库根，**仅在该 commit 有效**。上游持续更新，
把行号当「现状」引用前请先复核。

取得同一版本源码：

```bash
bash skills/x-algo-kb/scripts/fetch-source.sh          # clone 到 /tmp/x-algorithm
bash skills/x-algo-kb/scripts/fetch-source.sh ~/src/x  # 或指定目录
```

目标目录有未提交改动时脚本会拒绝执行，不会覆盖你的工作。

### 安装

技能本体在 `skills/x-algo-kb/`。复制或软链到你的 agent 技能目录即可：

```bash
# 用户级（所有项目可用）
ln -s "$(pwd)/skills/x-algo-kb" ~/.qoder/skills/x-algo-kb

# 或项目级
ln -s "$(pwd)/skills/x-algo-kb" /path/to/project/.qoder/skills/x-algo-kb
```

然后 `/skills reload` 或重启会话。用 `/x-algo-kb` 调用，或让它自动触发——
description 里带中英双语触发词（`限流`、`降权`、`推流`、`权重`、`涨粉`、`冷启动`、`风控`、
`shadowban`、`deamplification`）。

任何读 Agent Skills 格式（`SKILL.md` + bundled resources）的 agent 运行时都能用，
目录结构不绑定 Qoder。

### 主题路由

**只读**与问题对应的那一篇，每篇自包含。按语言选 `zh/` 或 `en/`，内容对等，不要两版都读。

| 文件 | 覆盖 |
|---|---|
| `01-architecture` | 两条流水线、29 模块地图、版本锚点、更新时间线、易踩坑 |
| `02-scoring-ranking` | 完整生产权重表、加权公式、互关加成、作者衰减、OON 折扣、冷启动 |
| `03-retrieval-filtering` | 召回配额、21 道打分前过滤、排序后过滤、会话去重 |
| `04-visibility-filtering` | severity fold、ALLOW/NOTICE/INTERSTITIAL/DROP、audience 语义、年龄门禁、法律下架 |
| `05-safety-labeling` | botmaker 规则语言、公开规则、处置档位、TTL、申诉豁免 |
| `06-account-credibility` | PageRank 信誉、agatha 比值、bdsm 行为模型、NSFW 校准曲线 |
| `07-models` | Phoenix 架构、双塔召回、损失函数、DPP 重排、索引前置风控 |
| `08-playbook` | 可执行打法、误解纠正、限流自查 |

路径：`skills/x-algo-kb/references/{zh,en}/<name>.md`。

### 六个最容易答错的点

以下每条都经过源码实证，是本知识库要防的主要错误。

1. **权重乘的是预测概率，不是互动计数。**「1 举报抵消 468 赞」是错的，
   上游专门写注释纠正（`xai-value-model/scoring.rs:34-44`）。当前比值约 330，
   **但即使 330 也不能读成计数等价**。

2. **作者多样性衰减与 OON 折扣不在 home-mixer 生效。**
   那里硬编码 false（`home-mixer/scorers/value_model.rs:46-49`），
   真正生效在 vm-ranker（`vm-ranker/scoring/value_model.rs:109-114`）。

3. **`vm-ranker/params.rs` 的权重默认值是旧的。**
   顶部无 sync 注释，`FavoriteWeight` 写 0.5，而 home-mixer 是 0.708（`param.rs:448-452`）。
   两者读同一个 feature switch key。**生产值一律以 `home-mixer/params/param.rs` 为准。**

4. **home-mixer 两个「新号」过滤器默认关闭，且「新号」指观众。**
   `EnableNewUserMinEngagementFilter` 与 `EnableNewUserSoftNsfwFilter` 都是 `false`
   （`param.rs:937-941,967-971`），年龄判定用 `query.user_id`——是**观众**不是作者
   （`new_user_min_engagement_filter.rs:70-77`）。它们不是新作者的门槛。
   新号真正的算法待遇是冷启动**扶持**。

5. **若干垃圾/回复标签掐的是通知，不是 For You 曝光。**
   `RISKY_HIGH_VIZ_REPLY`、`SPAM_HIGH_RECALL_OON`、`LOW_QUALITY_AND_UQF_DROPS`、
   `COMMUNITY_AND_SPAM_DROPS` 只接在通知面
   （`visibility-filtering/rules/levels.rs:253-297`），**未挂 `TIMELINE_HOME_RECOMMENDATIONS`**。
   「我评论了他没理我」不等于被限流。

6. **排序和可见性是两套独立系统。**
   「限流」通常是**推荐资格被布尔剥夺**——信誉标签 drop 规则挂在
   `TimelineHomeRecommendations`（thrift 61），而 `TimelineHome`（thrift 8）没有这类规则——
   或者根本没进召回索引。**不是分数被调低。** 诊断要查标签，不是查分数。

### 回答纪律

技能要求 agent：

- 区分**已验证的生产默认值** / **代码在但默认关闭** / **未公开**，
  并在影响结论时明确说是哪一档。
- 绝不把权重比值外推成互动计数等价。
- 对上游刻意未放出的内容（Grox LLM prompt、部分 botmaker 规则、
  若干被哨兵值或 mock 值替换的策略阈值）直接说「未公开」，不推断机制。
- 给涨粉建议时，分开「代码支持的」和「只是合理推测的」。

### 许可与署名

Apache-2.0，见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

本项目**与 xAI 或 X Corp. 无关联，未获其背书或赞助**。
「X」「Twitter」是各自所有者的商标，此处仅用于标识文档主题。