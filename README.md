# x-algo-kb

**English** | [简体中文](README.zh-CN.md)

[![License](https://img.shields.io/github/license/youngfreeFJS/x-algo-kb-skill)](LICENSE)
[![Stars](https://img.shields.io/github/stars/youngfreeFJS/x-algo-kb-skill)](https://github.com/youngfreeFJS/x-algo-kb-skill/stargazers)
![Upstream pinned](https://img.shields.io/badge/upstream-a284320b-blue)
![Docs](https://img.shields.io/badge/docs-16%20%C2%B7%20zh%20%2B%20en-green)

x-algo-kb answers questions about X's For You feed with the mechanism, the production number,
and the line of code it came from. It is built on [`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm),
the repository X publishes the feed code in, and it covers both **distribution** (how posts
get ranked and served) and **risk control** (how posts get labelled, restricted, or dropped).
It works in Claude Code, Codex, Cursor, Qoder, and any other agent that reads
[Agent Skills](https://agentskills.io).

**Without it:**
> Possibly shadowbanned. X reduces reach for accounts that look spammy. Try varying your
> wording, avoid posting many replies in a row, and check whether your posts still appear
> in search.

**With it:**
> No. Replies from accounts the viewer doesn't follow never enter the For You recommendation
> pool: `EnablePhoenixOonReplies = false` (`home-mixer/params/param.rs:71`). Your reply was
> only ever visible to people who already follow you or who opened the thread. Separately,
> `RISKY_HIGH_VIZ_REPLY` and `SPAM_HIGH_RECALL_OON` are wired only into notification surfaces
> (`visibility-filtering/rules/levels.rs:253-297`) and appear zero times in the
> `TIMELINE_HOME_RECOMMENDATIONS` block (`levels.rs:338-381`). They suppress notifications,
> not reach.

All 16 documents are checked mechanically against each other: for each of the 8 topics, the
Chinese and English versions have identical heading counts, table-row counts, and citation
multisets. Step 4 of the Quickstart lets you check the numbers against upstream yourself.

x-algo-kb is not a fork and vendors no upstream source. It is not affiliated with xAI or
X Corp. Every line number is pinned to commit `a284320b` and will drift as upstream ships
changes. Where upstream withheld something, the docs say **"not public"** and stop.

## The five findings that change what you do

1. **Dwell outweighs likes by one to two orders of magnitude.** `ContClickDwellTimeWeight`
   is 0.385 **per second** (`param.rs:549`); `FavoriteWeight` is 0.708 **times a predicted
   probability** (`param.rs:451`). A predicted 10-second dwell scores 3.85. A 0.1 like
   probability scores 0.0708. Write for read-through, not for likes.
2. **Your replies are never recommended to strangers.** `EnablePhoenixOonReplies = false`
   (`param.rs:71`). Commenting builds a relationship; it does not buy reach.
3. **The mutual-follow boost pays out on your later original posts.**
   `BidirectionalFollowReplyWeightBoost = 15.0` (`param.rs:458`) lifts reply weight from 5.0
   to 20.0 on a mutual-follow author's post, and eligibility requires
   `!is_reply && !is_retweet` (`xai-value-model/inputs.rs:20-22`).
4. **The first 200 impressions are the entire cold-start budget.** One post per request is
   lifted to position 16, gated on ≤50,000 followers, ≤7200s age, and <200 home impressions
   (`param.rs:691,697,703,709,715`). Past 200 the post leaves the pool permanently.
5. **"Spam smell" is arithmetic, not vibes.** `timing_regularity = 1 / (1 + std(Δt))` with Δt
   in milliseconds, and `engagement_without_impression` fires when a server action lands on a
   post that was never rendered (`bdsm/rust/abuse-v3-features/src/derived.rs:53-57,102-115`).
   100ms of interval jitter puts regularity below 0.01. Liking a post you never opened is a
   native signal.

Eight topics in all — see [What's inside](#whats-inside).

## Quickstart

Six checks. Each is a command with a literal expected result. Run them in order and stop at
the first failure. Steps 1–2 need Node.js 22.20 or newer.

### 1. Install

```bash
npx skills add youngfreeFJS/x-algo-kb-skill --skill x-algo-kb -a claude-code
```

Expected output contains:

```
✓ x-algo-kb (copied)
  → ./.claude/skills/x-algo-kb
```

Swap `-a claude-code` for `-a codex`, `-a cursor`, or `-a qoder`. Add `-g` to install across
all projects instead of the current one. Drop `--skill` and `-a` to pick interactively.

### 2. Confirm the files arrived

```bash
npx skills list
find .claude/skills/x-algo-kb -name '*.md' | wc -l
```

`skills list` must print a line starting `x-algo-kb` with
`Source: youngfreeFJS/x-algo-kb-skill`. The count must be exactly **17** — one `SKILL.md`
plus 8 Chinese and 8 English documents. Any other number means a partial install.

### 3. Fetch the pinned source

```bash
bash .claude/skills/x-algo-kb/scripts/fetch-source.sh
```

Expected output:

```
OK: source ready at pinned commit
path: /tmp/x-algorithm
commit: a284320b66a9dce35e6f5d6b052ee308eeb12326
```

A different commit means the citations in this KB do not apply to what you fetched. The
script refuses to run if the target directory has uncommitted changes.

### 4. Check four production numbers yourself

```bash
sed -n '71p;451p;458p;549p' /tmp/x-algorithm/home-mixer/params/param.rs
```

Expected output, exactly:

```
    false
    0.708
    15.0
    0.385
```

These are `EnablePhoenixOonReplies`, `FavoriteWeight`,
`BidirectionalFollowReplyWeightBoost`, and `ContClickDwellTimeWeight` — findings 1, 2 and 3
above, read straight from upstream.

### 5. Check the cold-start budget and the notification boundary

```bash
sed -n '691p;709p;715p' /tmp/x-algorithm/home-mixer/params/param.rs
sed -n '338,381p' /tmp/x-algorithm/visibility-filtering/rules/levels.rs \
  | grep -c 'RISKY_HIGH_VIZ_REPLY\|SPAM_HIGH_RECALL_OON'
```

First command prints `200`, `50000`, `7200` on three lines. Second prints **0** — those two
labels appear nowhere in the For You recommendations rule block. That zero is finding 5's
counterpart: the labels people blame for lost reach are not wired into reach at all.

### 6. Confirm the agent actually reads it

Paste this exact question into your agent:

```
What is BidirectionalFollowReplyWeightBoost set to, and which file and line?
```

**Pass:** the answer contains both `15.0` and `param.rs:458`.
**Fail:** a number with no `file:line`, or a claim that it cannot know. A fail means the skill
is installed but not being loaded — run `/skills reload`, or restart the session.

## Usage

Call it directly:

```
/x-algo-kb
```

Or ask in plain language, in either language. The description carries English and Chinese
trigger terms, so these all route to it:

```
Why did my post get zero impressions?
我的帖子零曝光，从哪查？
How much does mutual follow boost me?
互关加成是多少？
```

For a narrow question about one rule, label or parameter, grep the reference file instead of
loading it whole. Rule names, `SafetyLabelType` variants, parameter names and feature-switch
keys stay in English in both languages, so one pattern serves either:

```bash
grep -n "DO_NOT_AMPLIFY\|do_not_amplify" .claude/skills/x-algo-kb/references/zh/04-visibility-filtering.md
```

### Pick the language and the depth

Read `references/zh/` for Chinese, `references/en/` for English. The content is equivalent;
do not read both. `04`–`07` are full enumerations — the table below gives exact character
counts, reproducible with `wc -m`. Three of them end with a section you can read alone:
`04` §12 Diagnostic quick reference, `05` §12 Hard conclusions, `06` §10 Three-sentence
conclusion. `07` has no summary; grep it. For operational questions start at `08-playbook`.

## How it works

X assembles For You per request from two sources: in-network posts from accounts the viewer
follows, and out-of-network posts from ML retrieval. One transformer model, Phoenix, predicts
per-action probabilities for each candidate and blends them into a score using weights held
in `home-mixer/params/param.rs`.

Two systems then act on that score, and they are independent. **Ranking** decides order.
**Visibility filtering** decides whether the post can be shown at all, from the viewer's
blocks and mutes and from labels attached by botmaker, grox, agatha, bdsm and the media
models. A post can score high, rank third, and then be dropped.

This is why "shadowban" is the wrong frame. Deamplification is a boolean revocation of
recommendation eligibility, not a lowered score. Reputation-label drop rules attach to
`TimelineHomeRecommendations` (thrift 61); `TimelineHome` (thrift 8) has none
(`vf_client.rs:37-38`). Diagnose by reading labels, not scores.

## What's inside

| File | Covers | zh chars | en chars |
|---|---|---|---|
| [`01-architecture`](skills/x-algo-kb/references/en/01-architecture.md) | Two pipelines, 29-module map, version anchor, update timeline | 7852 | 13947 |
| [`02-scoring-ranking`](skills/x-algo-kb/references/en/02-scoring-ranking.md) | Production weight table, scoring formula, mutual-follow boost, author decay, OON discount, cold start | 9872 | 13989 |
| [`03-retrieval-filtering`](skills/x-algo-kb/references/en/03-retrieval-filtering.md) | Retrieval quotas, 21 pre-scoring filters, post-ranking filters, conversation dedup | 7829 | 12969 |
| [`04-visibility-filtering`](skills/x-algo-kb/references/en/04-visibility-filtering.md) | Severity fold, ALLOW/NOTICE/INTERSTITIAL/DROP, audience semantics, age gating, legal takedowns | 50198 | 63125 |
| [`05-safety-labeling`](skills/x-algo-kb/references/en/05-safety-labeling.md) | botmaker rule language, public rules, enforcement tiers, TTLs, appeal hold | 49729 | 69237 |
| [`06-account-credibility`](skills/x-algo-kb/references/en/06-account-credibility.md) | PageRank credibility, agatha ratios, bdsm behaviour model, NSFW calibration curves | 39244 | 55652 |
| [`07-models`](skills/x-algo-kb/references/en/07-models.md) | Phoenix architecture, two-tower retrieval, loss functions, DPP reranking, index-time VF | 37494 | 49171 |
| [`08-playbook`](skills/x-algo-kb/references/en/08-playbook.md) | Actionable tactics, myth-busting, shadowban self-diagnosis | 12872 | 24046 |

Swap `en/` for `zh/` for Chinese.

## Eight traps

Each was verified against source. Each is easy to get wrong even while reading the code
correctly.

| # | Trap | Evidence |
|---|---|---|
| 1 | Weights multiply predicted probabilities, not engagement counts. "1 report cancels 468 likes" is false; the current ratio is ≈330 and is still not a count equivalence. | `xai-value-model/scoring.rs:34-44` |
| 2 | Author diversity decay and the OON discount do not run in home-mixer. They are hardcoded off there and applied in vm-ranker. | `home-mixer/scorers/value_model.rs:46-49`, `vm-ranker/scoring/value_model.rs:109-114` |
| 3 | `vm-ranker/params.rs` defaults are stale: no sync stamp, `FavoriteWeight` reads 0.5. Same feature-switch key, so production uses one value. `home-mixer/params/param.rs` is authoritative. | `param.rs:448-452` |
| 4 | Both home-mixer "new user" filters default off, and "new user" means the **viewer**, not the author. | `param.rs:937-941,967-971`, `new_user_min_engagement_filter.rs:70-77` |
| 5 | Code present ≠ running in production. Multiplicative fusion, page-level RL exploration, MOE and SID retrieval, inventory holdout all default off; weight perturbation is a no-op at sigma 0. | `param.rs:189-193,370-374,596-600,845-849,1157-1161`, `weights.rs:145-148` |
| 6 | Ranking and visibility are separate systems. "Shadowban" is a visibility verdict or index exclusion, not a lowered score. | `vf_client.rs:37-38` |
| 7 | Several spam/reply labels suppress notifications, not For You reach. | `levels.rs:253-297` |
| 8 | A README "removed X" entry names one component in one module. Brazil's home-mixer filter is gone; visibility-filtering's rule is still wired. | `tweet_rules.rs:951-959` |

## Full example

**Question:** 我的号是不是有 spam 味？怎么查？

**Answer the KB produces:**

There is no single spam score. Four independent layers, and only one of them is queryable.

**Behaviour.** bdsm computes these from your action sequence
(`bdsm/rust/abuse-v3-features/src/derived.rs:81-148`; key names at `lib.rs:602-616`):

| Signal | Definition |
|---|---|
| `timing_regularity` | `1 / (1 + std(Δt))`, Δt in milliseconds. 100ms of jitter → below 0.01 |
| `engagement_without_impression` | server action id ∈ {1..10, 61, 62, 70} on a post with no prior render id ∈ {11, 12} |
| `action_burst_count` | actions within ±5 sequence positions and <1000ms of this one |
| `target_tweet_repetition` | max times one post was acted on ÷ sequence length |

**Account.** agatha ratios are percentile-calibrated against active users, so 0.99 is the
worst 1%. Production thresholds:
`AgathaSpamSuspended > 0.99 || AgathaAllSpamReportsPerFav > 0.999 || AgathaSpamReportsPerFav > 0.999`
→ `AGATHA_SPAM_TOP_USER`, TTL one week
(`ProductionAgatha__FilterOutOrganicNotifications.bot:18-33`). High-PageRank, gray-verified
and skiplist accounts are exempt.

**Content.** Of grox's 14 Spam policy types, four are labelled with no exemption at all:
`SpamEngagementBaiting`, `SpamEngagementFarming`, `SpamCardManipulation`, `SpamPromotesShares`.
Two never receive a Spam label: `SpamPromotesClicks`, `SpamPromotesReplies`. Everything else
is labelled only when the account is not high-PageRank
(`task_write_safety_post_annotations_result_sink.py:233-261`).

**Replies.** A separate 0–3 rubric. `score == 0.0` applies `RiskyHighVizReply`, and a new
score only overwrites an old one when it is lower — the reply score is monotonically
non-increasing (`grox/flows/reply_spam/task_write.py:127-141`).

**How to check.** Open [Under the Hood](https://x.com/i/jf/under_the_hood). It shows the
labels actually on your account and posts, whether any manual label bypassed automation, and
whether a post is withheld in a country by legal demand. It does not expose agatha or bdsm
model scores. bdsm's enforcement thresholds are redacted: `sink_policy.yaml:5-15` replaces
them with a `9.99` sentinel and a `999999` count gate. The `12.34` and `12345.67` in the
enforcement service YAML are mock values, as their own comments state. Any published
"score above X gets you banned" number is invented.

## Sources

- [`xai-org/x-algorithm`](https://github.com/xai-org/x-algorithm), Apache-2.0, pinned at
  `a284320b66a9dce35e6f5d6b052ee308eeb12326` (2026-11-17T03:20:50Z).
- Parameter baseline: the sync stamp at `home-mixer/params/param.rs:1` → `2026-11-16T16:00:37Z`.
- [Under the Hood](https://x.com/i/jf/under_the_hood) is X's own label transparency tool;
  its serving code is in `under-the-hood/`.

Every citation is relative to the upstream root at that commit. Re-fetch with
`scripts/fetch-source.sh` before quoting a line number as current.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Not affiliated with, endorsed by, or sponsored by xAI or X Corp. "X" and "Twitter" are
trademarks of their respective owners, used only to identify the subject of the documentation.

If x-algo-kb saves you from a wrong answer, a star helps other people find it.
