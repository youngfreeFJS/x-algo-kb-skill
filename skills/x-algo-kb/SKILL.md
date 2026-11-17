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

| Question shape | Reference file | Size (zh / en chars) |
|---|---|---|
| Architecture, module map, what the repo does/doesn't contain, update history | `01-architecture` | 7852 / 13947 |
| Weights, scoring formula, mutual-follow boost, author decay, OON discount, cold start | `02-scoring-ranking` | 9872 / 13989 |
| Retrieval quotas, which posts get filtered out, thread dedup, why a reply gets no reach | `03-retrieval-filtering` | 7829 / 12969 |
| ALLOW/NOTICE/INTERSTITIAL/DROP rules, legal takedowns, age gating | `04-visibility-filtering` | **50198 / 63125** |
| What triggers a safety label, botmaker rules, enforcement tiers, appeals | `05-safety-labeling` | **49729 / 69237** |
| Account credibility, PageRank, block/report ratios, inauthentic behavior, NSFW scoring | `06-account-credibility` | **39244 / 55652** |
| Phoenix model architecture, two-tower retrieval, loss functions, DPP reranking | `07-models` | **37494 / 49171** |
| Actionable growth tactics, myth-busting, shadowban self-diagnosis | `08-playbook` | 12872 / 24046 |

Files live at `references/{zh,en}/<name>.md`. Read the file before answering; if a
listed file is absent, say that topic is not yet covered rather than improvising.

### Reading strategy for the four large docs

`04`–`07` are exhaustive rule/model enumerations, 37,494–50,198 characters in Chinese
and 49,171–69,237 in English (`wc -m` reproduces these). **Do not read them whole for a
narrow question.** Instead:

1. For a specific rule, label, param or model component, **grep the file first** for
   its identifier (rule names, `SafetyLabelType` variants, param names and
   feature-switch keys are kept in original English in both languages, so one grep
   pattern works for `zh/` and `en/`). Then read only the surrounding section.
   ```
   grep -n "DO_NOT_AMPLIFY\|do_not_amplify" references/zh/04-visibility-filtering.md
   ```
2. Three of the four end with a condensed section you can read alone when the
   question is "what does this mean for me" rather than "enumerate every rule":
   `04` §12 Diagnostic quick reference, `05` §12 Hard conclusions you can quote
   directly, `06` §10 Three-sentence conclusion. `07` has no such summary — its
   last section lists what is absent from the repo; use grep for `07`.
3. Read the whole file only when the question genuinely needs the complete set
   (e.g. "list every rule that drops a post for non-followers").
4. `08-playbook` is the cheap entry point for reach/shadowban/growth questions and
   cross-references the deep docs. Start there when the question is operational.

## Non-obvious traps

These cause wrong answers even when reading the source correctly. Details and
citations are in `01-architecture`, `02-scoring-ranking`, `04-visibility-filtering`
and `05-safety-labeling`.

1. **Weights multiply predicted probabilities, not engagement counts.** "1 report
   cancels 468 likes" is wrong. Upstream wrote comments specifically to correct
   this (`xai-value-model/scoring.rs:34-44`).
2. **Author diversity and OON discount do not run in home-mixer.** They are
   hardcoded off there (`home-mixer/scorers/value_model.rs:46-49`) and actually
   applied in vm-ranker (`vm-ranker/scoring/value_model.rs:109-114`).
3. **`vm-ranker/params.rs` defaults are stale** (no sync stamp; FavoriteWeight
   reads 0.5). Both modules read the same feature-switch key. Treat
   `home-mixer/params/param.rs` as authoritative.
4. **Both home-mixer "new user" filters are OFF by default, and "new user" means
   the viewer.** `EnableNewUserMinEngagementFilter` and `EnableNewUserSoftNsfwFilter`
   are both `false` (`param.rs:937-941,967-971`); the age check uses `query.user_id`
   (`new_user_min_engagement_filter.rs:70-77`). They are not a gate on new authors —
   a new account's real treatment is the cold-start **boost**.
5. **Many capabilities are off by default** — multiplicative fusion
   (`MultiplicativeVmEngageBias = 0.0`), page-level RL exploration, MOE and SID retrieval
   sources, inventory holdout (`param.rs:189-193,370-374,596-600,845-849,1157-1161`), and
   weight perturbation (`WeightPerturbationSigma = 0.0`, `vm-ranker/params.rs:188-192`;
   `perturbed` early-returns at sigma ≤ 0, `xai-value-model/weights.rs:145-148`).
   Code present ≠ running in production.
6. **Ranking and visibility are separate systems.** "Shadowban" is usually a
   visibility verdict or exclusion from the retrieval index, not a lowered score.
   Reputation-label drop rules attach to `TimelineHomeRecommendations` (thrift 61);
   `TimelineHome` (thrift 8) has none (`vf_client.rs:37-38`).
7. **Several spam/reply labels suppress notifications, not For You reach.**
   `RISKY_HIGH_VIZ_REPLY`, `SPAM_HIGH_RECALL_OON`, `LOW_QUALITY_AND_UQF_DROPS` and
   `COMMUNITY_AND_SPAM_DROPS` are wired only into notification surfaces
   (`visibility-filtering/rules/levels.rs:253-297`), never into
   `TIMELINE_HOME_RECOMMENDATIONS`. "They never replied to my comment" is not a
   shadowban.
8. **A README "removed X" entry names one component in one module.** The Brazil
   election filter is two layers: home-mixer's `Brazil2026ElectionFilter` is gone,
   but visibility-filtering's `brazil_election_legal/drop/undesirable` is still
   wired under `RequestCountryIs("br")` (`tweet_rules.rs:951-959`). Check for a
   same-named rule in other modules before repeating a removal as a global fact.

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