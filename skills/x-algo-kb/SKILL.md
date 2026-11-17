---
name: x-algo-kb
description: Evidence-backed knowledge base for X (Twitter) For You feed algorithm, derived from the open-source xai-org/x-algorithm repository. Covers ranking weights and scoring formula, mutual-follow boost, author diversity decay, out-of-network discount, new-author cold start, retrieval quotas, pre/post-scoring filters, visibility filtering (ALLOW/NOTICE/INTERSTITIAL/DROP), safety labeling and enforcement, account credibility models, and Phoenix ranking/retrieval models. Use when asked about X/Twitter reach, shadowban, deamplification,限流, 降权, 推流, 推荐机制, 权重, 涨粉, 冷启动, 风控, 安全标签, why a post got no impressions, or how to grow an account on X. Also use when auditing claims about the X algorithm or reading xai-org/x-algorithm source code. 中文触发词：推特算法、X 算法、信息流排序、限流排查、被屏蔽、曝光量低、互关加成、举报降权、新号扶持。
---

# X Algorithm Knowledge Base

## Overview

Answer questions about how X's For You feed distributes and restricts posts, using
verified findings from the official open-source algorithm repository instead of
speculation or re-reading 29MB of source.

Every claim in the reference docs carries a `path:line` citation pinned to one
commit. Numbers are production defaults, not guesses.

## Source version anchor

| Item | Value |
|---|---|
| Upstream | `https://github.com/xai-org/x-algorithm` (Apache-2.0) |
| Pinned commit | `a284320b66a9dce35e6f5d6b052ee308eeb12326` |
| Commit date | `2026-11-17T03:20:50Z` |
| Param sync stamp | `home-mixer/params/param.rs:1` → `2026-11-16T16:00:37Z` |

All `path:line` citations are relative to the upstream repo root and valid **only
at this commit**. Upstream ships ongoing changes; re-verify before quoting line
numbers as current.

## How to use

1. Pick the topic below and read **only** the matching reference file. Do not load
   all of them — each is self-contained.
2. Match the user's language: `references/zh/` for Chinese, `references/en/` for
   English. Content is equivalent; do not read both.
3. Quote the numbers and the citation. Prefer "weight is 0.708
   (`home-mixer/params/param.rs:451`)" over "likes are weighted low".
4. If the answer needs source verification, run `scripts/fetch-source.sh` first,
   then read the cited file. Never assume a previous clone still exists.

## Topic routing

| Question shape | Reference file |
|---|---|
| Architecture, module map, what the repo does/doesn't contain, update history | `01-architecture` |
| Weights, scoring formula, mutual-follow boost, author decay, OON discount, cold start | `02-scoring-ranking` |
| Retrieval quotas, which posts get filtered out, thread dedup, why a reply gets no reach | `03-retrieval-filtering` |
| ALLOW/NOTICE/INTERSTITIAL/DROP rules, legal takedowns, age gating | `04-visibility-filtering` |
| What triggers a safety label, botmaker rules, enforcement tiers, appeals | `05-safety-labeling` |
| Account credibility, PageRank, block/report ratios, inauthentic behavior, NSFW scoring | `06-account-credibility` |
| Phoenix model architecture, two-tower retrieval, loss functions, DPP reranking | `07-models` |
| Actionable growth tactics, myth-busting, shadowban self-diagnosis | `08-playbook` |

Files live at `references/{zh,en}/<name>.md`. Read the file before answering; if a
listed file is absent, say that topic is not yet covered rather than improvising.

## Non-obvious traps

These cause wrong answers even when reading the source correctly. Details and
citations are in `01-architecture` and `02-scoring-ranking`.

1. **Weights multiply predicted probabilities, not engagement counts.** "1 report
   cancels 468 likes" is wrong. Upstream wrote comments specifically to correct
   this (`xai-value-model/scoring.rs:34-44`).
2. **Author diversity and OON discount do not run in home-mixer.** They are
   hardcoded off there (`home-mixer/scorers/value_model.rs:46-49`) and actually
   applied in vm-ranker (`vm-ranker/scoring/value_model.rs:109-114`).
3. **`vm-ranker/params.rs` defaults are stale** (no sync stamp; FavoriteWeight
   reads 0.5). Both modules read the same feature-switch key. Treat
   `home-mixer/params/param.rs` as authoritative.
4. **"New user" in `NewUserMinEngagementFilter` means the viewer, not the author**
   (`new_user_min_engagement_filter.rs:74` uses `query.user_id`).
5. **Many capabilities are off by default** — multiplicative fusion, weight
   perturbation, page-level RL exploration, MOE/SID retrieval, inventory holdout.
   Code present ≠ running in production.
6. **Ranking and visibility are separate systems.** "Shadowban" is usually a
   visibility verdict or exclusion from the retrieval index, not a lowered score.

## Answering discipline

- Distinguish **verified production default** from **experiment / disabled code**.
  State which one when it changes the conclusion.
- When upstream deliberately withheld something (Grox LLM prompts, some botmaker
  rules), say "not public" instead of inferring the mechanism.
- Do not extrapolate weight ratios into engagement-count equivalences.
- For growth advice, separate what the code supports from what is merely plausible.
  Example: replies from non-followed accounts are filtered out of For You by
  default, so "comment on big accounts to get your replies recommended" is false;
  the real payoff is the mutual-follow boost on later original posts.

## Resources

- `references/zh/*.md` — Chinese reference docs, 8 topics
- `references/en/*.md` — English reference docs, same 8 topics
- `scripts/fetch-source.sh` — clone upstream at the pinned commit for citation
  verification. Usage: `bash scripts/fetch-source.sh [target-dir]`