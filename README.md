# x-algo-kb

**English** | [简体中文](README.zh-CN.md)

[![License](https://img.shields.io/github/license/youngfreeFJS/x-algo-kb-skill)](LICENSE)
[![Stars](https://img.shields.io/github/stars/youngfreeFJS/x-algo-kb-skill)](https://github.com/youngfreeFJS/x-algo-kb-skill/stargazers)
![Upstream pinned](https://img.shields.io/badge/upstream-a284320b-blue)
![Docs](https://img.shields.io/badge/docs-16%20%C2%B7%20zh%20%2B%20en-green)

A knowledge base of X's For You feed algorithm that your agent can install. It covers both
**distribution** (how posts get ranked and served) and **risk control** (how posts get
labelled, restricted, or dropped), and every claim carries a `path:line` citation into
[`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm).

Works in Claude Code, Codex, Cursor, Qoder, and any other agent that reads the
[Agent Skills](https://agentskills.io) format.

---

Ask an agent about X reach without this and you get plausible advice. Ask with it and you
get the mechanism, the production number, and the line of code it came from.

> **Question:** I replied to a big account and they never replied back. Am I shadowbanned?

**Without the KB** — sounds reasonable, sends you down the wrong path:

> Possibly. X reduces reach for accounts that look spammy. Try varying your wording, avoid
> posting many replies in a row, and check whether your posts still appear in search.

**With the KB** — the question mixes up two separate systems:

> No. Two independent reasons, neither of which is a reach penalty:
>
> 1. Replies from accounts the viewer doesn't follow **never enter the For You
>    recommendation pool at all** — `EnablePhoenixOonReplies = false`
>    (`home-mixer/params/param.rs:71`). Your reply was only ever visible to people who
>    already follow you or who opened the thread.
> 2. The labels usually blamed for this — `RISKY_HIGH_VIZ_REPLY`, `SPAM_HIGH_RECALL_OON`,
>    `LOW_QUALITY_AND_UQF_DROPS` — are wired **only into notification surfaces**
>    (`visibility-filtering/rules/levels.rs:253-297`) and never into
>    `TIMELINE_HOME_RECOMMENDATIONS`. They can suppress a notification, not your reach.

**What this is not.** Not a fork, and no upstream source is vendored here. Not affiliated
with xAI or X Corp. Every line number is pinned to one commit and will drift as upstream
ships changes. Where upstream deliberately withheld something, the docs say **"not public"**
instead of guessing.

## Quickstart

Requires Node.js 22.20+ for the installer.

```bash
npx skills add youngfreeFJS/x-algo-kb-skill
```

Pick your agent when prompted. Add `-g` to install across all projects instead of just the
current one. Non-interactive:

```bash
npx skills add youngfreeFJS/x-algo-kb-skill --skill x-algo-kb -a claude-code -g
```

<details>
<summary>Manual install, or an agent the CLI doesn't know</summary>

```bash
git clone https://github.com/youngfreeFJS/x-algo-kb-skill.git
cd x-algo-kb-skill

# user-level
ln -s "$(pwd)/skills/x-algo-kb" ~/.qoder/skills/x-algo-kb
# or project-level
ln -s "$(pwd)/skills/x-algo-kb" /path/to/project/.qoder/skills/x-algo-kb
```

For Claude Code use `~/.claude/skills/`, for Codex `~/.codex/skills/`. Any runtime that reads
`SKILL.md` + bundled resources works; the layout is not Qoder-specific.
</details>

Then reload skills (`/skills reload`) or restart the session. Invoke with `/x-algo-kb`, or
just ask — the description carries English and Chinese trigger terms (`shadowban`,
`deamplification`, `限流`, `降权`, `推流`, `权重`, `涨粉`, `冷启动`, `风控`).

## Try these four questions

Each one is a working test: if the answer lacks the number and the citation, the skill isn't
being read. Expected content is listed so you can check.

### 1. "How much does mutual follow actually boost me?"

Expect: `BidirectionalFollowReplyWeightBoost = 15.0` (`param.rs:458`) takes the reply weight
on a mutual-follow author's **original post** from 5.0 to 20.0 — 4×. Eligibility is
`!is_reply && !is_retweet && is_mutual_follow_author` (`xai-value-model/inputs.rs:20-22`).

The payoff lands on your later original posts, not on the replies you wrote to build the
relationship. That distinction is the whole reason "go comment on big accounts" advice is
half wrong.

### 2. "What does a brand-new account actually get?"

Expect a **boost**, not a penalty — and a hard budget:

| Gate | Production value | Citation |
|---|---|---|
| Original post only (no reply, no retweet) | required | `author_cold_start.rs:189-190` |
| Author followers | ≤ 50,000 | `param.rs:709` |
| Post age | ≤ 7200s (2h) | `param.rs:715` |
| Home impressions on that post | < 200 | `param.rs:691` |
| Slots lifted per request | **1** | `author_cold_start.rs:216-226` |
| Lifted to position | **16th** | `param.rs:697,703` |

Selection is Thompson sampling with `Beta(0.75, 49.25)` — a 1.5% prior like rate
(`param.rs:741,747`). **The first 200 impressions are the entire trial budget**; past that
the post leaves the cold-start pool permanently.

### 3. "Are likes the thing I should optimize for?"

Expect: no. `click_dwell_time` carries **0.385 per second** (`param.rs:549`) while `favorite`
carries **0.708 × predicted probability** (`param.rs:451`). A predicted 10-second dwell scores
3.85; a 0.1 like probability scores 0.0708. **Dwell outweighs likes by one to two orders of
magnitude** — the most underrated lever in the current algorithm.

Both October 2026 upstream updates pushed further toward duration: ranking improved
time-spent prediction (Oct 8), then retrieval was trained to surface posts people read all
the way through (Oct 13).

### 4. "My post got zero impressions. Where do I look?"

Expect four distinct failure classes, not one blurry "shadowban":

| Class | What happened | Where to look |
|---|---|---|
| **A** | Never entered the retrieval index | index-time visibility filtering |
| **B** | Indexed, then dropped by a visibility rule | `04-visibility-filtering` |
| **C** | Ranked low or deduped into another post | `02` / `03` |
| **D** | Shown, but notifications suppressed | `levels.rs:253-297` |

Diagnose by reading labels, not scores. Reputation-label drop rules attach to
`TimelineHomeRecommendations` (thrift **61**); `TimelineHome` (thrift **8**) has none
(`vf_client.rs:37-38`). Deamplification is a **boolean revocation of recommendation
eligibility**, not a lowered score.

## What's inside

Eight topics, each in Chinese and English, content-equivalent. Read **only** the file
matching your question, in your language.

| File | Covers | Size (zh / en chars) |
|---|---|---|
| [`01-architecture`](skills/x-algo-kb/references/en/01-architecture.md) | Two pipelines, 29-module map, version anchor, update timeline | 8k / 14k |
| [`02-scoring-ranking`](skills/x-algo-kb/references/en/02-scoring-ranking.md) | Production weight table, scoring formula, mutual-follow boost, author decay, OON discount, cold start | 10k / 14k |
| [`03-retrieval-filtering`](skills/x-algo-kb/references/en/03-retrieval-filtering.md) | Retrieval quotas, 21 pre-scoring filters, post-ranking filters, conversation dedup | 8k / 13k |
| [`04-visibility-filtering`](skills/x-algo-kb/references/en/04-visibility-filtering.md) | Severity fold, ALLOW/NOTICE/INTERSTITIAL/DROP, audience semantics, age gating, legal takedowns | **50k / 63k** |
| [`05-safety-labeling`](skills/x-algo-kb/references/en/05-safety-labeling.md) | botmaker rule language, public rules, enforcement tiers, TTLs, appeal hold | **50k / 69k** |
| [`06-account-credibility`](skills/x-algo-kb/references/en/06-account-credibility.md) | PageRank credibility, agatha ratios, bdsm behaviour model, NSFW calibration curves | **39k / 56k** |
| [`07-models`](skills/x-algo-kb/references/en/07-models.md) | Phoenix architecture, two-tower retrieval, loss functions, DPP reranking, index-time VF | **37k / 49k** |
| [`08-playbook`](skills/x-algo-kb/references/en/08-playbook.md) | Actionable tactics, myth-busting, shadowban self-diagnosis | 13k / 24k |

Swap `en/` for `zh/` for Chinese.

**`04`–`07` are exhaustive enumerations** — loading one whole costs roughly 30–40k tokens in
Chinese or 13–18k in English. For a narrow question, grep for the identifier first and read
only the surrounding section. Rule names, `SafetyLabelType` variants, param names and
feature-switch keys stay in English in both languages, so one pattern works for either:

```bash
grep -n "DO_NOT_AMPLIFY\|do_not_amplify" skills/x-algo-kb/references/zh/04-visibility-filtering.md
```

Three of the four end with a condensed section readable on its own: `04` §12 Diagnostic
quick reference, `05` §12 Hard conclusions, `06` §10 Three-sentence conclusion. `07` has no
summary. For operational questions start at `08-playbook`, the cheapest entry point.

## Eight traps that cause wrong answers

These are the errors this KB exists to prevent. Each was verified against source, and each
is easy to get wrong *even while reading the code correctly*.

1. **Weights multiply predicted probabilities, not engagement counts.** "One report cancels
   468 likes" is wrong — upstream wrote comments specifically to correct it
   (`xai-value-model/scoring.rs:34-44`). The current ratio is ≈330, and even that is not a
   count equivalence.
2. **Author diversity decay and the OON discount do not run in home-mixer.** Hardcoded off
   there (`home-mixer/scorers/value_model.rs:46-49`); actually applied in vm-ranker
   (`vm-ranker/scoring/value_model.rs:109-114`).
3. **`vm-ranker/params.rs` weight defaults are stale.** No sync stamp; `FavoriteWeight` reads
   0.5 while home-mixer reads 0.708. Same feature-switch key, so production uses one value.
   Treat `home-mixer/params/param.rs` as authoritative.
4. **Both home-mixer "new user" filters are off by default, and "new user" means the
   viewer.** `param.rs:937-941,967-971`; the age check uses `query.user_id`
   (`new_user_min_engagement_filter.rs:70-77`). Not a gate on new authors.
5. **Code present ≠ running in production.** Multiplicative fusion, page-level RL
   exploration, MOE and SID retrieval, inventory holdout all default off
   (`param.rs:189-193,370-374,596-600,845-849,1157-1161`); weight perturbation is a no-op at
   sigma 0 (`weights.rs:145-148`).
6. **Ranking and visibility are separate systems.** "Shadowban" is usually a visibility
   verdict or index exclusion, not a lowered score.
7. **Several spam/reply labels suppress notifications, not For You reach.**
   `levels.rs:253-297`. "They never replied to my comment" is not a shadowban.
8. **A README "removed X" entry names one component in one module.** The Brazil election
   filter is two layers: home-mixer's is gone, visibility-filtering's
   `brazil_election_legal/drop/undesirable` is still wired under `RequestCountryIs("br")`
   (`tweet_rules.rs:951-959`).

## How it stays honest

- **One pinned commit.** All citations are relative to the upstream root at
  `a284320b66a9dce35e6f5d6b052ee308eeb12326` (2026-11-17T03:20:50Z); the parameter baseline is
  the sync stamp at `home-mixer/params/param.rs:1` → `2026-11-16T16:00:37Z`.
- **Production defaults, not experiment values.** The docs distinguish verified default from
  disabled code from not-public, and say which one whenever it changes the conclusion.
- **"Not public" is a real answer.** Grox LLM prompts, several botmaker rules, and some
  policy thresholds replaced with sentinel or mock values are marked as withheld rather
  than inferred. `12.34` and `12345.67` in the enforcement service are official mocks, not
  thresholds.
- **Bilingual parity is checked mechanically.** Heading counts, table-row counts and
  citation multisets match exactly between `zh/` and `en/` for all eight topics.

To check any citation yourself:

```bash
bash skills/x-algo-kb/scripts/fetch-source.sh          # clones into /tmp/x-algorithm
bash skills/x-algo-kb/scripts/fetch-source.sh ~/src/x  # or a directory you choose
```

The script pins the exact commit and refuses to run if the target directory has uncommitted
changes, so it will not overwrite your work.

## License and attribution

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Derived from [`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm), also Apache-2.0.
This project is **not affiliated with, endorsed by, or sponsored by xAI or X Corp.** "X" and
"Twitter" are trademarks of their respective owners, used only to identify the subject of the
documentation.
