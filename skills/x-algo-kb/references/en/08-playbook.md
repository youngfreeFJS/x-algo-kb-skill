# 08 · Playbook: what the code supports, and what it does not

> Synthesis of the previous seven documents. Every conclusion is tagged:
> **[verified]** = production default + `path:line`; **[inferred]** = mechanically plausible but not directly evidenced; **[not public]** = deliberately withheld upstream.
> Evidence pinned to commit `a284320b66a9dce35e6f5d6b052ee308eeb12326`.

---

## 1. Four different kinds of "no impressions" — four different diagnoses

This is the most important section. Most "I've been shadowbanned" claims fail because
they **treat four distinct failures as one**.

| # | Failure | Where | Symptom | Self-checkable |
|---|---|---|---|---|
| A | **Never entered the retrieval index** | `phoenix-rankall-strato` (offline, at post time) | Post looks normal on your profile but never appears in For You — not even for your followers | Indirectly |
| B | **Indexed, then DROPped by online VF** | `home-mixer/filters/vf_filter.rs` (post-ranking) | Score may be high, rank may be #3, then it vanishes | Under the Hood shows labels |
| C | **Shown, but ranked low / deduplicated** | Scoring + `DedupConversationFilter` | Some impressions but few; or only one post of a thread appears | Compare impressions vs engagement rate |
| D | **Only the notification was suppressed** | `visibility-filtering/rules/levels.rs:253-297` | The person you replied to got no notification, but the reply itself is fine in For You | Hard |

**A and B are visibility problems, C is a ranking problem, D is not an impressions problem at all.**
Two independent systems (see `01-architecture` §1).

### 1.1 Class D is the one most often mistaken for a shadowban

`RISKY_HIGH_VIZ_REPLY`, `SPAM_HIGH_RECALL_OON`, `LOW_QUALITY_AND_UQF_DROPS` and
`COMMUNITY_AND_SPAM_DROPS` are wired **only into notification surfaces**:

| Constant | Wired at | Surface |
|---|---|---|
| `COMMUNITY_AND_SPAM_DROPS` | `levels.rs:253,292` | `NOTIFICATIONS_WRITER_V2_MENTION`, `_RETWEET_SOURCE` |
| `LOW_QUALITY_AND_UQF_DROPS` | `levels.rs:258,297` | same two |
| `RISKY_HIGH_VIZ_REPLY_OON_DROP_UNSPECIFIED` | `levels.rs:259,275` | `_MENTION`, `_MEDIA_TAGGED` |
| `SPAM_HIGH_RECALL_OON_DROP_UNDESIRABLE` | `levels.rs:274` | `_MEDIA_TAGGED` |

`NOTIFICATIONS_WRITER_V2_REPLY = NOTIFICATIONS_WRITER_V2_MENTION` (`levels.rs:262`).

**None of these constants is wired into `TIMELINE_HOME_RECOMMENDATIONS` (For You) or `TIMELINE_HOME` (Following).**

Concrete consequence: Grox's `RISKY_HIGH_VIZ_REPLY` label (botmaker rule 25026,
`spamScore >= 0.97`, TTL 14 days) stops the person you replied to from being
**notified**. It does not remove your reply from For You.
"I commented on a big account and they never responded" ≠ "I've been shadowbanned".

### 1.2 State the boundary of class A carefully

Index admission calls VF **with no viewer context**:

```
phoenix-rankall-strato/lib/eventProcessing.strato:260-279
  shouldDropTweet(safetyLevel = TimelineHomeRecommendations, forUserId = None)
  defaults to false (allow) on error
```

Because `forUserId = None`, every viewer-relative condition (`ViewerFollowsAuthor`,
`ViewerBlocksAuthor`, age, settings) **cannot be resolved normally**. Therefore:

- [verified] Index admission uses the recommendations safety level and fails open.
- [not public / not determinable] **Which audience-gated rules actually fire at index time**
  cannot be determined from this repo. Do not assert it.

---

## 2. What "deamplification" actually means: boolean revocation, not a score discount

### 2.1 Two audience concepts — never conflate them

| Audience | Meaning | Who can still see it |
|---|---|---|
| `NonFollowers` | Dropped for **non-followers** | Author + followers, normally |
| `NonAuthors` | Dropped for **everyone except the author** | **Only the author** (followers are dropped too) |

`NonAuthors` is far harsher than what people usually mean by "shadowban" — it hides
the post from your own followers.

### 2.2 Recommendations and Following are two rule sets

`visibility-filtering-client/vf_client.rs:37-38`:

```rust
TimelineHome = 8,
TimelineHomeRecommendations = 61,
```

Reputation-label `NonFollowers` / `NonAuthors` drop rules attach to **61 (recommendations)**.
**The user section of 8 (Following) has no reputation-label rules at all.**

**So "deamplification" = boolean revocation of recommendation eligibility.** Your followers
still see you in Following; strangers never see you again. The score was not multiplied
by 0.1 — the post **never enters the candidate set**.

### 2.3 Severity fold (strictest wins when multiple labels hit)

`visibility-filtering/rules/action_kind.rs:59-129`:

| ActionKind | severity | Lands | Actual effect |
|---|---|---|---|
| `Appealable` | **18** | Fosnr | Appealable withholding |
| `Drop` | **17** | Withheld | Not shown |
| `Tombstone` | **16** | Withheld | Tombstone placeholder |
| `LabelInterstitial` | 11 | Slot | Click-through mask + notice |
| `MediaRestriction` | 10 | Slot(Media) | Media restricted |
| `SoftIntervention` | 8 | Fosnr | Soft intervention |
| `LimitedEngagement` | **6** | Slot(Engagement) | Engagement only (e.g. reply restriction), **display unaffected** |

**Note the gap between 6 and 17.** `LimitedEngagement` only restricts interaction; the post
is still shown. "Your replies are limited" does not mean "your posts are deamplified".

### 2.4 Collateral removal: the easiest trap

`AncillaryVFFilter`: if **any** ancestor / quoted / retweeted post is DROPped, your post is removed too.

And quoted posts and ancestors are **always sent at the stricter recommendations level**,
even when your own post is in-network:

| Sent for review | Safety level |
|---|---|
| In-network posts + the retweeted source | `TimelineHome` (8, looser) |
| Out-of-network posts + **all ancestors** + **all quoted posts** | `TimelineHomeRecommendations` (61, stricter) |

Evidence: `home-mixer/candidate_hydrators/vf_candidate_hydrator.rs:67-106`.

**Two actionable conclusions**:
1. Quoting a borderline post is riskier than posting the same content yourself.
2. Replying under an already-deamplified post gets your reply removed via the ancestor.

---

## 3. Self-diagnosis path (in order)

### Step 1: use the official transparency tool, do not guess

**Under the Hood**: <https://x.com/i/jf/under_the_hood> (`README.md:470`)

It shows:
- **Which visibility-impacting labels are actually on your account and posts** (aggregate statistics)
- **Whether any manual label bypassed the automated systems**
- **Withholding in a specific country due to legal requirements** (added 2026-09-18)

The jobs and serving code that build the report are in `under-the-hood/`; the rendering page
is in `under-the-hood/jetfuel/`.

**This is the only entry point that shows real labels.** Any "I think I'm shadowbanned"
without this step is a guess.

### Step 2: decide which of A/B/C/D you have

```
Does the post open normally on your profile?
├─ No → account-level enforcement (suspension/restriction), not a distribution problem
└─ Yes
   ├─ Can your followers see it in the Following feed?
   │   ├─ No → not reputation-label deamplification (level 8 has no such rules)
   │   │        check: 48h window / seen dedup / conversation dedup / block-mute graph
   │   └─ Yes, but strangers cannot → class B, recommendation eligibility revoked
   │                                   go back to step 1 and read the labels
   ├─ Only one specific post has no impressions, others are fine?
   │   → check AncillaryVFFilter: is the post you quoted/retweeted/replied to flagged?
   ├─ A reply has no impressions?
   │   → expected. Strangers' replies do not enter the recommendation pool by default
   │     (§4.2). Not a shadowban.
   └─ The other person says they got no notification?
       → class D, notification-surface rules, unrelated to For You
```

### Step 3: rule out these normal mechanisms that are not deamplification

| Symptom | Real cause | Evidence |
|---|---|---|
| An old post suddenly stops getting impressions | Hard 48-hour window | `AgeFilter`, `params/config.rs:41` |
| Only one post of a thread appears | One slot per conversation, highest score wins | `dedup_conversation_filter.rs:19-36` |
| Later posts in the same burst get very little | Author diversity decay 0.625 / 0.4375 | `scoring.rs:304-325` |
| Cannot see the same post twice | Seen + served dedup (10 minutes / 100 posts) | `param.rs:1280,1286` |
| A new post dies after ~200 impressions | Permanently exits the cold-start pool | `param.rs:691` |
| A retweet/quote silently disappears | The source author blocked you | `author_socialgraph_filter.rs:24-45` |

### 3.1 Appeals

`abuse-ledger-service/` records appeal overturns, and the overturn-hold path in
`abuse-enforcement-service` consults it before re-enforcing, skipping when it hits.
**But that gate defaults to off**:

```rust
// abuse-enforcement-service/service-lib/src/overturn_hold.rs:150-163
mode: GateMode::Off,
on_probe_error: OnProbeError::Allow,
kinds: vec![GateKind::Suspend],
```

[verified] Default `Off`, default covers **suspensions only**, and **fails open**
(re-enforces normally) when the ledger probe errors.
[not public] Whether production enables the gate, and the exact exemption duration.

So the precise statement is: **an overturn is recorded and blocks re-application when the
gate is enabled** — not an unconditional "a successful appeal grants permanent immunity".

Also, `12.34` / `12345.67` in the `abuse-enforcement-service` YAMLs are **explicitly
commented as mock values** (`enforcement_user.yaml:20,26`, `enforcement_post.yaml:24,30`).
Never quote them as real gates.

### 3.2 Removing a label does not restore visibility immediately

Safety labels are cached, and the delay differs by direction
(`safety-label-source/dragonfly.rs:248-253`):

| Cache entry | Default TTL | Consequence |
|---|---|---|
| `Found` (label present) | **24 hours** (`:63`) | After a label is **removed**, the stale "present" entry can live up to 24h → **visibility recovery can lag a day** |
| `NotFound` (no label) | **1 hour** (`:64`) | After a label is **added**, the stale "absent" entry can live up to 1h → enforcement can lag an hour |

`MIN_TTL = 60s` floor (`:44`); both are overridable by feature switch (`:97-100`).

**But these are hard-expiry upper bounds, not guaranteed delays.** `due_refresh`
(`dragonfly.rs:160-170`) triggers **one** refresh (step 0 → 1, not continuous) for a step-0
entry aged ≥ `REFRESH_AFTER` (60s, `:30`), and `refresh_cutoff_ms` can force a full re-fill
of entries older than the cutoff. The complete refresh scheduling loop is not shipped, so
**exact real-world recovery latency is not determinable from this repo**.

What is actionable is the **direction**: post-removal lag comes from the "label present"
cache (24h bound), not the "no label" cache. If visibility has not recovered the same day
an appeal succeeded, do not immediately conclude the appeal failed.

---

## 4. Tactics the code supports [verified]

Ordered by leverage.

### 4.1 Dwell time is the single largest lever right now

| Term | Weight | Magnitude example |
|---|---|---|
| `click_dwell_time` | **0.385 / second** | Predicted 10s dwell after click = **3.85 points** |
| `favorite` | 0.708 | Like probability 0.1 = **0.0708 points** |
| `dwell_time` | 0.0075 / second | Dwell without a click, far smaller |

Evidence: `param.rs:549,451,543`.

**One to two orders of magnitude apart.** And both upstream updates in October 2026
strengthened dwell modeling (10-08 ranking model improved dwell prediction; 10-13 the
retrieval model was also trained to surface posts people read through).

Actionable:
- Write content that **requires reading to the end to be worth anything**, not content
  people glance at and swipe past
- Long-form text and images that need expanding are structurally favoured (`photo_expand`
  is also a positive head)
- Dwell **after a click** is worth 51× dwell without one (0.385 / 0.0075).
  **Getting someone to click in** beats getting them to linger in the feed.

### 4.2 Original posts > replies > retweets, and the gap is structural

Three independent mechanisms stack:

1. **Strangers' replies and retweets never enter the recommendation pool**
   `EnablePhoenixOonReplies = false` (`param.rs:71`), `oon_retweet_reply_filter.rs:16-28`
2. **The mutual-follow boost applies only to original posts**
   `bidirectional_boost_eligible = !is_reply && !is_retweet && is_mutual_follow_author`
   (`xai-value-model/inputs.rs:20-22`)
3. **Even for someone you follow, their replies and retweets get the 0.75 discount**
   `EnableOonRescoreForInNetworkRepliesRetweets = true` (`vm-ranker/params.rs:218-222`)

**So "comment more, post less" is right as a growth tactic, but the mechanism is not
"your comments get recommended".** See §5.1.

### 4.3 Mutual follows are the only explicit relationship dividend in the algorithm

`BidirectionalFollowReplyWeightBoost = 15.0` (`param.rs:458`)
→ for a mutual-follow author's **original post**, reply weight goes **5.0 → 20.0, a 4× increase**.

The payoff chain:
```
Comment on big accounts → seen by the author / other readers → they follow back
  → mutual follow established
  → your ORIGINAL post gets reply weight 5 → 20 in their For You
  → more likely to be served to them → more real engagement → further spread
```

History matters: pushed to 20 on 2026-07-13, rolled back to **15** on 07-24 because users
complained during the World Cup that they were not seeing enough out-of-network discussion
(`docs/BIDIRECTIONAL_BOOST_CHANGE.md`). **This value gets tuned; do not treat 20 as a constant.**

`bidirectional_follow_dwell_weight_boost` was tested in the same period but **never rolled
out**; production value 0.0 (`param.rs:464`).

### 4.4 New accounts: the first 200 impressions are the entire trial budget

Cold-start eligibility (all must hold):

| Condition | Threshold | Evidence |
|---|---|---|
| Original post (not a reply, not a retweet) | Hard | `author_cold_start.rs:189-190` |
| Author follower count ≤ | 50,000 | `param.rs:709` |
| Post age ≤ | 7200 seconds (2 hours) | `param.rs:715` |
| Home impressions on this post < | **200** | `param.rs:691` |

**Only 1 slot per request**, lifted to position 16 (`ColdStartSlotMin=15, Max=16`, `param.rs:697,703`).
Selection uses Thompson sampling with prior `Beta(0.75, 49.25)` → mean 1.5% like rate
(`param.rs:741,747`).

Actionable:
- **New accounts should not post replies or retweets** — they cannot win a cold-start slot
- The first 2 hours are the window. **Post when your target audience is online**
  [inferred: audience online-hours have no code evidence, but the 2-hour window is verified]
- Once impressions exceed 200 the post exits permanently. **There is no second chance.**
- A 0-impression post beats a 10000-impression 0-like post in sampling
  (`author_cold_start.rs:988-1007`) — the uncertainty bonus is real

### 4.5 Do not burst-post, do not spam long threads

| Behaviour | Consequence | Evidence |
|---|---|---|
| 2nd post in the same burst | × 0.625 | `scoring.rs:304-325`, decay 0.5 / floor 0.25 |
| 3rd post in the same burst | × 0.4375 | same |
| 5 posts in one thread | **At most 1** in For You | `dedup_conversation_filter.rs:19-36` |

**A long thread does not buy you more slots.** To get multiple slots you need
**different conversations** spread across **different time windows**.

### 4.6 Do not quote or retweet borderline content

See §2.4. Quoted posts are reviewed at the stricter level, plus collateral removal.
**This is the worst risk/reward trade in the whole safety system**: you take on the risk
of someone else's content.

### 4.7 Engagement pods and report brigades do not work

`xai-value-model/scoring.rs:46-58`, upstream's own words:

> For an account to count in the algorithms recommendation system, it must take place on a post served in Home Timeline. Directly navigating to a post (i.e., coordinating via groupchat) has no ranking impact.

**Sharing a link in a group chat to organise likes or reports has no ranking impact**,
because those actions do not happen inside For You.
Likewise, malicious reports mainly affect recommendations for **people similar to the
reporter** (prediction is personalised), not a network-wide downrank.

### 4.8 What blue verification actually does: enters the PageRank teleport seed set

**It is not a ranking boost.** There is no verified-related term anywhere in the weight table.

The real mechanism is in the account credibility model:

```scala
// user-cred-v2/UserCredV2App.scala:174
validUserInfoPipe.filter(u => !u.isNearZero && u.isPremium).map(u => UserMass(u.id, 1.0))
// user-cred-v2/ValidUserInfo.scala:14-15
def isPremium = isBlueVerified || isGrayVerified || isGoldVerified || isVerifiedOrg || isVOAffiliate
```

teleport vector = `(1 - beta) × normalized uniform + beta × normalized engagement`,
with `beta = engagement_teleport_beta = 0.5` (`UserCredV2Config.scala:35,183`).

**The uniform half goes only to verified accounts.** So buying blue verification does put
you into the credibility model's seed set and raises your PageRank baseline — and PageRank
feeds the safety exemption gates
(`botmaker-rules/scarecrow/derived-feature/HighPageRankThreshold.df:2` = **54**,
`grox/flows/reply_spam/constants.py:9` = **66**).

**Precise statement**: blue verification affects **the probability that you get safety-labelled**,
not **your post's ranking score**. These two are constantly conflated.

### 4.9 The popular pool is for big accounts only

`TOP_POSTING_AUTHORS_FRACTION = 0.00005` (`home-mixer/util/popular_authors.rs:11`)
→ the **top 0.005%** of active posters over the last 7 days, ranked by follower count,
refreshed hourly.

New accounts can only rely on Phoenix retrieval, SimClusters and the cold-start slot.

---

## 5. Myth-busting

### 5.1 "Comment on other people's posts and the algorithm will recommend your comments" — half right

**Right**: commenting on other accounts does grow followers.
**Wrong**: the mechanism is not the algorithm recommending your comments.

Your reply is **not** recommended to strangers (`EnablePhoenixOonReplies = false`).
Its impressions come entirely from:
- People who open that post's detail page and read the replies (**manual exposure**)
- Your own followers seeing it in For You (in-network replies can enter, but × 0.75)
- The author you replied to getting a notification (**and this can be suppressed by class D rules**)

The algorithmic payoff lands on **your original posts after the mutual follow exists** (§4.3).

**So "only comment, never post" is wrong**: comments build relationships, but the
relationship dividend can only be collected by original posts. You need both.

### 5.2 "One report cancels 468 likes" — wrong

Weights multiply **predicted probabilities**, not counts. `xai-value-model/scoring.rs:34-44`
carries a comment specifically correcting this.
Also, the current ratio is `report / favorite = 234 / 0.708 ≈ 330`; 468 is a stale value.
**But even 330 must not be read as a count equivalence** — the baseline probability of a
report is over 1000× lower than a like, and the high weight exists so a rare event can
influence ranking at all.

### 5.3 "New accounts have a posting threshold / new accounts are throttled" — wrong

Both home-mixer "new user" filters are **disabled by default**:
- `EnableNewUserMinEngagementFilter = false` (`param.rs:937-941`)
- `EnableNewUserSoftNsfwFilter = false` (`param.rs:967-971`)

And even if enabled, "new user" means the **viewer**, not the author:

```rust
// home-mixer/filters/new_user_min_engagement_filter.rs:70-77
duration_since_creation_opt(query.user_id)   // ← query.user_id is the VIEWER
```

It is "content-quality protection for new viewers", not "a distribution limit on new authors".
**A new account's actual algorithmic treatment is the cold-start boost (§4.4), which is positive.**

### 5.4 "External links get downranked" — no such penalty in the ranking code

There is **no** external-link penalty parameter in `home-mixer/params/param.rs`;
`open_link` is a **positive head** at 0.2 (`param.rs:480`).

But keep the layers separate: `UNTRUSTED_URL` is a **safety label** acting on visibility /
notification surfaces, not a ranking downrank.
[verified] No external-link penalty in ranking. [inferred] A post with an external link may
produce shorter post-click dwell (the user navigates away), indirectly losing
`click_dwell_time` score — **this is a mechanism inference, not direct code evidence.**

### 5.5 "Posting time / hashtag count / keyword density is magic" — no code evidence

The ranking inputs in this repo contain **no** feature-engineering terms for posting hour,
hashtag count or keyword density. Phoenix's inputs are **your behaviour sequence + post
content embeddings** (see `07-models`).

[not public] Grox's LLM prompts (the j2 files) are withheld, so the feature set extracted by
the content-understanding layer **cannot be enumerated**. Do not claim "there is none" —
only "there is none in the ranking weight table".

### 5.6 "Deamplification means the score was lowered" — wrong

See §2.2. It is **boolean revocation of recommendation eligibility**, not multiplication by
a factor below 1. The diagnosis is completely different: read labels, not scores.

### 5.7 "Author decay / OON discount live in home-mixer" — wrong module

home-mixer **hardcodes author diversity to false** (`home-mixer/scorers/value_model.rs:46-49`);
it actually applies in vm-ranker (`vm-ranker/scoring/value_model.rs:109-114`).
Reading only home-mixer leads to the false conclusion "there is no author downrank".

Also, `vm-ranker/params.rs` has **no sync stamp** at the top and its `FavoriteWeight` reads 0.5,
while home-mixer is synced to 0.708 (`param.rs:448-452`). Both read the **same switch key**
`rust_home_mixer_favorite_weight`. **Always treat home-mixer as authoritative for production values.**

---

## 6. What cannot be concluded from the code [not public]

Upstream's README `What's not in this repo?` admits these are withheld to reduce gaming risk:

| Gap | Consequence |
|---|---|
| **Grox LLM prompts** (j2 files) | Cannot enumerate what the content-understanding layer extracts |
| **Some botmaker rules** | Cannot list every labelling trigger |
| Real `abuse-enforcement-service` thresholds | `12.34` / `12345.67` in the YAMLs are explicitly commented as mock |
| `bdsm/runtime/sink_policy.yaml` operating points | All sentinels `9.99` (probabilities) / `999999` (counts); **head names, structure and action mappings are real, thresholds are not** |
| Index-time audience resolution | `forUserId = None`; cannot determine which viewer-relative rules fire |

**For these questions the correct answer is "not public", not an inferred mechanism.**

The compensation is Under the Hood (§3 step 1) — it reports **actual outcomes on your
account**, which is more reliable than inferring rules.

---

## 7. One-page lookup

| Goal | What the code says | Where |
|---|---|---|
| Raise impressions on one post | Maximise post-click dwell (0.385/s) | `02-scoring-ranking` §2.2 |
| Grow followers | Comment to build mutuals → original posts collect the 4× reply weight | `02` §3 + this doc §5.1 |
| Start a new account | Original posts only; capture the first 2 hours / first 200 impressions | `02` §4.3 + this doc §4.4 |
| How many posts per day | Spread across time windows; 2nd in a burst gets 0.625 | `02` §4.1 |
| Should I post long threads | For You keeps only 1; no extra slots | `03-retrieval-filtering` §3.1 |
| Should I quote a hot post | Quoted posts reviewed strictly + collateral removal; high risk | `03` §3.2-3.3 |
| Is blue verification worth it | Enters the PageRank seed set, lowers labelling probability; **no ranking boost** | this doc §4.8 |
| Engagement pods | No effect; actions must occur inside For You | this doc §4.7 |
| Suspect a shadowban | Open Under the Hood first, then classify A/B/C/D | this doc §1 + §3 |
| Nobody responds to my replies | Possibly only the notification was suppressed, not a reach problem | this doc §1.1 |