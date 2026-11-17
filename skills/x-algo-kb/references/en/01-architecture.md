# 01 · Architecture: The Two Pipelines Behind X's For You Feed

> Source: [xai-org/x-algorithm](https://github.com/xai-org/x-algorithm), Apache 2.0
> Code size: ~29MB, 700 `.rs` + 568 `.scala` + 489 `.py` + 313 `.java` files
> Param sync stamp: `home-mixer/params/param.rs:1` → `2026-11-16T16:00:37Z`

## Version anchor and how to re-verify

Every line-number citation in this knowledge base is based on the version below.
**Align the version before re-verifying**, otherwise the line numbers will not line up:

| Item | Value |
|---|---|
| Repository | `https://github.com/xai-org/x-algorithm` |
| commit | `a284320b66a9dce35e6f5d6b052ee308eeb12326` |
| Commit date | `2026-11-17T03:20:50Z` |

Preferred way to obtain that exact version — the bundled script:

```bash
bash scripts/fetch-source.sh                 # defaults to /tmp/x-algorithm
bash scripts/fetch-source.sh /path/to/target # optional target directory
```

Usage is `bash scripts/fetch-source.sh [target-dir]`. It clones or updates the
checkout and detaches HEAD at the pinned commit, and it **refuses to proceed if the
target has uncommitted changes**, so it never discards local work.

Manual alternative:

```bash
git clone https://github.com/xai-org/x-algorithm.git /tmp/x-algorithm
cd /tmp/x-algorithm && git checkout a284320b66a9dce35e6f5d6b052ee308eeb12326
```

All paths in this document are relative to the repo root. For example,
`home-mixer/params/param.rs:451` means line 451 of
`/tmp/x-algorithm/home-mixer/params/param.rs`.

**Note**: upstream keeps shipping changes (the README's Notable Updates section is
the changelog). If `git log` shows new commits, read the diff of
`home-mixer/params/param.rs` first — weight and threshold changes land there.
`docs/BIDIRECTIONAL_BOOST_CHANGE.md` is the official worked example of such a change.

---

## 1. The one sentence that matters most

**X's recommendation system is two completely independent systems:**

| | Ranking | Visibility |
|---|---|---|
| Decides | **where** a post ranks | **whether** a post can be shown to you at all |
| Services | `phoenix/` + `vm-ranker/` | `visibility-filtering/` |
| Inputs | your behavior sequence + post features | safety labels on the account/post + your relationship with the author + your settings/country |
| Output | a score | ALLOW / NOTICE / INTERSTITIAL / DROP |

README, `Key Design Decisions` item 4, verbatim:

> Ranking decides the order. Visibility filtering decides whether a post can be shown at all. Different services, different inputs, different rules.

**This is the key to understanding deamplification**: in the vast majority of cases
being "shadowbanned" is not "your score was lowered" — it is **a DROP or a downgrade
in the visibility layer**, or **never entering the retrieval index at all**. The two
systems are diagnosed in completely different ways.

---

## 2. Request path (what happens during one For You request)

```
FOR YOU REQUEST
    │
    ▼  home-mixer/  ── POST PIPELINE (PhoenixCandidatePipeline)
    │
    ├─ 1. Query hydration ── home-mixer/query_hydrators/
    │     your recent engagement sequence (main model input), following list, blocks/mutes,
    │     muted keywords, seen/served posts, followed topics, geo, device, inferred gender…
    │
    ├─ 2. Candidate retrieval (parallel) ── home-mixer/sources/
    │     in-network: Thunder (in-memory real-time pool, 1200 posts)
    │     out-of-network: Phoenix two-tower retrieval (1000) + cold start (200)
    │                     SimClusters (community clusters) + Popular posts (500)
    │
    ├─ 3. Candidate hydration ── home-mixer/candidate_hydrators/
    │     text/media, author info and account labels, quoted post, language,
    │     engagement counts, subscription status, mutual-follow check, VF labels…
    │
    ├─ 4. Pre-scoring filters (21 of them) ── home-mixer/filters/
    │     48 hours, replies/retweets from non-followed accounts, seen posts, mutes, subscriptions…
    │
    ├─ 5. Scoring
    │     PhoenixScorer  → one probability per action
    │     RankingScorer  → weighted sum
    │     VMRanker       → calls vm-ranker/ to recompute + DPP reranking
    │
    ├─ 6. Selection ── TopKScoreSelector (sort by score, take top K)
    │
    └─ 7. Post-ranking filters ── VFFilter / AncillaryVFFilter / DedupConversationFilter
          ◄── labels come from the LABELING PATH
    │
    ▼  BLENDING PIPELINE (ForYouCandidatePipeline)
    │
    ├─ BlenderSelector blends in non-post content: ads, Who to Follow, prompts, push-to-home
    │  default ads blender: slot_spread (param.rs:1052)
    │
    └─ SIDE EFFECTS (after the response is sent) ── record served posts, refresh caches, logging
    │
    ▼
Final For You timeline
```

---

## 3. Labeling path (safety systems; not on the request path, runs continuously)

```
1. Content understanding (at post time / offline batch)
   Posts and media                                  Accounts
   ├─ grox/              text + media classifiers   ├─ agatha/       how others react to your posts
   ├─ media-model-proxy/ image/video models         │                (blocks / reports / spam reports ÷ likes)
   └─ clip/              text-image embeddings      ├─ bdsm/         behavior sequences → inauthentic behavior
                                                    └─ user-cred-v2/ follow graph + engagement graph PageRank
    │
    ▼
2. Labeling rules
   ├─ scarecrow/         event-driven. Embeds botmaker/ as its rule engine,
   │                     rules come from botmaker-rules/scarecrow/
   │                     rule shape: on event, if condition, apply label
   ├─ abuse-enforcement-service/  driven by model scores (not events):
   │                     labeling / verification challenge / suspension
   │                     enforcement overturned on appeal is not reapplied (abuse-ledger-service/)
   └─ safety-label-user-agg/      aggregates post labels into account labels
    │
    ▼
3. Persisted to storage (read back on the request path)
    │
    ▼
4. visibility-filtering/  decided per post × per viewer
   ALLOW        shown normally
   NOTICE       shown + an attached notice
   INTERSTITIAL shown behind a click-through overlay (adult / gory media)
   DROP         not shown
    │
    ▼
5. home-mixer/filters/vf_filter.rs + ancillary_vf_filter.rs
   DROP → removed after ranking; ancestor / quoted / retweeted post DROPped → this post removed too
   INTERSTITIAL / NOTICE → the post stays in the feed (overlay and notice are drawn by the client, not in this repo)
```

---

## 4. Module map (29 top-level directories)

### 4.1 Request path

| Directory | Language | Responsibility |
|---|---|---|
| `home-mixer/` | Rust | For You assembly: pipelines, weights, downstream calls |
| `candidate-pipeline/` | Rust | pipeline framework: source / hydrator / filter / scorer / selector / side effect |
| `thunder/` | Scala | in-network real-time in-memory post pool |
| `phoenix/` | Python(JAX) + Rust | retrieval two-tower + ranking transformer, training and serving |
| `phoenix-rankall/` | Scala | retrieval index maintenance |
| `phoenix-rankall-strato/` | Strato | decides which index a post enters, **consults visibility filtering first** |
| `simclusters/` | Scala | community-cluster retrieval |
| `vm-ranker/` | Rust | DPP diversity reranking + value model recomputation |
| `xai-value-model/` | Rust | weighted fusion formula and weight structures |

### 4.2 Content understanding

| Directory | Responsibility |
|---|---|
| `grox/` | text/media classifiers run at post time (the j2 files with the LLM prompts are **not public**) |
| `media-model-proxy/` | image/video model serving: adult, violence/gore, hate symbols, topics, known-media matching |
| `clip/` | text-image embedding model training |
| `adult-content/` | adult media classifier training and calibration |
| `pnsfwmedia/` | adult classifier fusing CLIP embeddings + account scores (including agatha calibration scores) |
| `agatha/` | offline batch: ratios of others' reactions → account labels |
| `bdsm/` | behavior sequences → inauthentic/abusive behavior scores |
| `user-cred-v2/` | follow graph + engagement graph PageRank → account credibility score |

### 4.3 Safety and visibility

| Directory | Responsibility |
|---|---|
| `visibility-filtering/` | per-post per-viewer decisions, rules live in `rules/` |
| `visibility-filtering-client/` | client + safety label type definitions |
| `botmaker/` | rule engine: language, compiler, runtime |
| `botmaker-rules/` | rules loaded by scarecrow (**some rules are not public**) |
| `scarecrow/` | event-driven labeling service |
| `abuse-enforcement-service/` | enforcement driven by model scores |
| `abuse-ledger-service/` | appeal hold periods |
| `safety-label-source/` | label provenance and storage |
| `safety-label-user-agg/` | post labels → account label aggregation |
| `takedowns/` | list of legal takedown reasons |
| `under-the-hood/` | transparency reporting: statistics on visibility-limiting labels on accounts/posts |

---

## 5. What the repo explicitly does *not* contain

The README's `What's not in this repo?` section admits that, to reduce the risk of
being gamed, the following are not published:

- **Grox's LLM prompts** (the specific j2 files)
- **Some botmaker rules**

The compensation is the [Under the Hood](https://x.com/i/jf/under_the_hood)
transparency tool: you can see which visibility-impacting labels have actually been
applied to your account and posts, including **whether a manual label was applied
outside the automated systems**, and **whether a post was withheld in a country
because of a legal requirement** (2026-09-18 update).

Deployment-related files (builds, infrastructure imports such as `xai_service_runner`
/ `xai_kafka`) are mostly absent as well. Only `phoenix/` is designed to run
end-to-end (it ships a Cargo workspace, `pyproject.toml`, `QUICKSTART.md`, and
synthetic data generation).

---

## 6. Update timeline worth remembering

| Date | Change | Why it matters |
|---|---|---|
| 2026-07-13 → 07-24 | mutual-follow reply boost 20 → **15** | during the World Cup users complained they saw too little out-of-network discussion; deliberately dialed back |
| 2026-08-13 | first public release of weights, visibility filtering, Phoenix training code, SimClusters | the big transparency release |
| 2026-08-14 | clarification of how weights work + Brazil election filter | corrects the "1 report = 468 likes" misreading |
| 2026-09-18 | Under the Hood adds legal-compliance visibility information | you can see which country withheld a post |
| 2026-10-08 | ranking model improves time-spent prediction | `phoenix/xrex/models/loss_recsys.py` |
| 2026-10-13 | retrieval model also trained to surface posts people read all the way through | `recsys_two_tower_model.py` |
| 2026-10-26 | Brazil election filter removed | the election ended |
| 2026-11-16 | param sync (the numeric baseline for this knowledge base) | |

**The trend is unmistakable: a shift from engagement counts toward attention
duration / read-through rate.** Both October 2026 updates reinforce duration modeling.

---

## 7. Navigating this knowledge base

| Doc | Topic |
|---|---|
| `01-architecture` | this doc: architecture, module map, update timeline |
| `02-scoring-ranking` | weight tables, scoring formula, mutual-follow boost, author decay, OON discount, cold start |
| `03-retrieval-filtering` | retrieval quotas, 21 pre-scoring filters, post-selection filters, conversation dedup |
| `04-visibility-filtering` | ALLOW/NOTICE/INTERSTITIAL/DROP rules, OON-only rules, legal takedowns |
| `05-safety-labeling` | botmaker rule language, public rules, enforcement tiers, appeal holds |
| `06-account-credibility` | PageRank credibility, agatha ratios, bdsm behavior features, adult-content scoring |
| `07-models` | Phoenix architecture, two-tower retrieval, loss functions, DPP, index-side pre-filtering |
| `08-playbook` | actionable conclusions, myth corrections, deamplification self-diagnosis |

Files live at `references/{zh,en}/<name>.md`.

---

## 8. The five easiest traps when reading this repo

1. **Weights are not count multipliers.** They multiply predicted probabilities.
   `scoring.rs:34-44` carries a comment written specifically to correct this.
2. **The README says the three multiplicative adjustments happen in RankingScorer;
   they actually happen in vm-ranker.** `home-mixer/scorers/value_model.rs:46-49`
   hardcodes author diversity to false; the version that takes effect is
   `vm-ranker/scoring/value_model.rs:109-114`.
3. **The defaults in `vm-ranker/params.rs` are stale** (no sync comment at the top,
   `FavoriteWeight` reads 0.5). It reads the same feature-switch key as home-mixer,
   so the production value is the one in `home-mixer/params/param.rs` (which is synced).
4. **"New user" in `NewUserMinEngagementFilter` means the viewer, not the author**
   (`new_user_min_engagement_filter.rs:74` uses `query.user_id`).
5. **Many capabilities are off by default**: multiplicative fusion, weight
   perturbation, page-level RL exploration, inventory holdout, near-zero OON for new
   viewers, MOE retrieval, SID retrieval. Code present ≠ running in production.