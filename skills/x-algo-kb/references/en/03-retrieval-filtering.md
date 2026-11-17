# 03 · Retrieval and Filtering: Whether a Post Enters the Pool At All

> Evidence base: `home-mixer/candidate_pipeline/phoenix_candidate_pipeline.rs`,
> `home-mixer/filters/*`, `home-mixer/params/param.rs`

**Ranking decides the order; filtering decides life or death.** If a post is filtered
out, no score can save it. Filtering happens in two passes: before scoring (to save
compute) and after ranking (visibility enforcement).

---

## 1. Retrieval sources and quotas (production defaults)

| Source | Type | Quota | Enabled | Evidence |
|---|---|---|---|---|
| **Thunder** | in-network, in-memory real-time pool | **1200** | yes | `param.rs:27` |
| **Phoenix retrieval** | out-of-network, two-tower vector retrieval | **1000** | yes | `param.rs:8` |
| Phoenix cold-start retrieval | out-of-network, new posts only | **200** | yes | `param.rs:20` |
| **SimClusters** | out-of-network, community clusters | — | yes | `param.rs:52` |
| **Popular posts** | out-of-network, shared popular pool | **500** | yes | `param.rs:1251` |
| Phoenix MOE | out-of-network, experiment | 0 | **no** | `param.rs:192,216` |
| TweetMixer | — | 800 | **no** | `param.rs:45` |
| SID (semantic IDs) | — | 800 | **no** | `param.rs:848` |

SimClusters candidates have a maximum age of **48 hours** (`param.rs:842`).

### 1.1 Scoring budget and "fair share"

The cap on candidates entering Phoenix scoring: **2800** (`PhoenixScoresResultSize`,
`param.rs:1513`).

When candidates exceed the budget, `FairShareRankingFilter` trims **proportionally
per retrieval source** rather than taking a global top slice
(`home-mixer/filters/fair_share_ranking_filter.rs:59-101`, largest-remainder method):

```rust
// fair_share_ranking_filter.rs:90-101
let groups = group_by_served_type(candidates);   // group by retrieval source
let keep = fair_share_counts(&demands, budget);  // split the 2800 slots proportionally
```

Unit-test example (`fair_share_ranking_filter.rs:135-158`): in-network 440 +
SimClusters 220 + Phoenix 440 = 1100 candidates, budget 1000 → keep 400 / 200 / 400,
i.e. **every source is scaled by the same 90.9% factor**.

**Implication**: a surge from one retrieval source cannot squeeze out the others.
Out-of-network content does not drown out in-network content just because there is
more of it.

### 1.2 How the popular-author pool is selected

`home-mixer/util/popular_authors.rs:11,25-43`:

```rust
pub const TOP_POSTING_AUTHORS_FRACTION: f64 = 0.00005;
let k = (active_posters_7d as f64 * fraction).ceil();
Ok(by_followers_desc[..k].to_vec())
```

It takes the **top 0.005% of accounts that posted in the last 7 days, ordered by
follower count**. Refreshed hourly (`REFRESH_INTERVAL_MS = 60*60*1000`,
`popular_authors.rs:8`).

**Implication**: the popular pool is a lane reserved for large accounts; new accounts
cannot get in. A new account can only rely on Phoenix retrieval, SimClusters, and the
cold-start quota.

---

## 2. Pre-scoring filters (in actual execution order)

The authoritative order comes from
`home-mixer/candidate_pipeline/phoenix_candidate_pipeline.rs:433-455`:

| # | Filter | What it kills | Key detail |
|---|---|---|---|
| 1 | `DropDuplicatesFilter` | the same post returned by multiple sources | |
| 2 | `ZeroFavCodivertFilter` | experiment bucketing | off by default (`ViewerZeroFavCodivertIsTreatment=false`) |
| 3 | `CoreDataHydrationFilter` | posts whose text/metadata failed to load | |
| 4 | `NewUserSoftNsfwFilter` | new viewer + soft NSFW | off by default (`param.rs:970`); thresholds: account younger than 7 days, behavior sequence <100 |
| 5 | **`AgeFilter`** | **posts older than 48 hours** | `MAX_POST_AGE = 48*60*60`, `params/config.rs:41` |
| 6 | `SelfTweetFilter` | your own posts | |
| 7 | **`OONRetweetReplyFilter`** | **retweets and replies from accounts you do not follow** | see §2.1 below, the most important one |
| 8 | `OONNsfwSimclustersFilter` | out-of-network SimClusters posts from NSFW-labeled accounts | `oon_nsfw_simclusters_filter.rs:19-24` |
| 9 | `RetweetDeduplicationFilter` | duplicate retweets of the same post | |
| 10 | `IneligibleSubscriptionFilter` | subscriber-only posts you are not subscribed to | `ineligible_subscription_filter.rs:22-26` |
| 11 | `PreviouslySeenPostsFilter` | posts already shown to you | |
| 12 | `PreviouslySeenPostsBackupFilter` | same, against a second impression record | |
| 13 | `PreviouslyServedPostsFilter` | posts already served in this session | also checks **quoted / retweeted / ancestor** posts (`related_post_ids_iter`) |
| 14 | `ViewerMutedKeywordFilter` | hits on keywords you muted | |
| 15 | `AuthorSocialgraphFilter` | block/mute relationships | see §2.2, broader than you would expect |
| 16 | `VideoFilter` | video posts when the request excludes video | |
| 17 | `TopicIdsFilter` | posts outside the requested topic | |
| 18 | `NewUserMinEngagementFilter` | low-engagement out-of-network posts shown to new viewers | off by default, see §2.3 |
| 19 | `InventoryHoldoutFilter` | random holdout by percentage | off by default, all three percents are 0 (`param.rs:1160-1178`) |
| 20 | `FavHoldoutFilter` | holdout ratio based on like count | off by default (`param.rs:1185`) |
| 21 | **`FairShareRankingFilter`** | whatever exceeds the 2800 budget | trimmed per source, see §1.1 |

### 2.1 The single most important rule: replies from non-followed accounts never enter the recommendation pool

`home-mixer/filters/oon_retweet_reply_filter.rs:16-28`:

```rust
let allow_phoenix_oon_replies = query.params.get(EnablePhoenixOonReplies);  // default false
let root_only = query.params.get(PhoenixOonRepliesRootOnly);
FilterResult::partition(candidates, |c| {
    let is_reply = c.in_reply_to_tweet_id.is_some();
    let is_retweet = c.retweeted_tweet_id.is_some();
    let oon_reply_dropped = is_reply
        && !(allow_phoenix_oon_replies && is_phoenix_home_retrieval(c) && (!root_only || replies_to_root));
    !((c.in_network == Some(false) && (is_retweet || oon_reply_dropped))
        || (is_reply && c.ancestors.is_empty()))
})
```

Unpacked into three hard rules:

1. **A retweet by an author you do not follow → dropped outright**
2. **A reply by an author you do not follow → dropped outright**
   (`EnablePhoenixOonReplies = false`, `param.rs:71`)
3. **Any reply whose ancestor chain is missing → dropped outright** (followed or not)

**This determines how commenting on other accounts' posts actually works**:

Your reply is **not** recommended to strangers by the algorithm. Its impressions come
entirely from:

- people who open that post's detail page (including the large account's followers)
  and read the replies
- your own followers seeing it in For You (in-network replies do get in, but with the
  0.75 discount — see `02-scoring-ranking` §4.2)
- the author you replied to, who gets a notification

So commenting on bigger accounts is **manual exposure + relationship building**, not
"getting the algorithm to recommend your comment". The algorithmic payoff lands on
**your original posts after the mutual follow is established**.

### 2.2 Social-graph filtering is broader than you would expect

`home-mixer/filters/author_socialgraph_filter.rs:24-45` — any one hit drops the post:

- you muted the author
- you blocked the author
- **the author blocked you**
- **the author of the quoted post blocked you**
- you blocked the author of the quoted post
- you blocked the author of the retweeted post

**Implication**: a retweet or quote can be killed because of **the original author's**
relationship with you, not just the retweeter's.

### 2.3 The "new user" filter refers to the viewer, not the author

An easy misreading. `home-mixer/filters/new_user_min_engagement_filter.rs:70-77`:

```rust
fn within_account_age(query: &ScoredPostsQuery) -> bool {
    duration_since_creation_opt(query.user_id)   // ← query.user_id is the viewer
        .map(|age| age < Duration::from_secs(max_age_secs))
}
```

It checks whether the **viewer's account** is younger than 1800 seconds (30 minutes)
or inside the resurrection window, and then filters out **out-of-network** candidates
with an engagement rate below 0.004
(`new_user_min_engagement_filter.rs:60-68`; `in_network != Some(false)` passes through
unconditionally).

**Disabled by default in production** (`EnableNewUserMinEngagementFilter = false`,
`param.rs:940`).

**This is not a "posting threshold for new accounts", it is "content-quality protection
for new viewers".** Do not misread it as a restriction on new authors.

---

## 3. Post-ranking filters (where visibility enforcement takes effect)

Order from `phoenix_candidate_pipeline.rs:516-520`:

| # | Filter | Effect |
|---|---|---|
| 1 | **`VFFilter`** | removes posts visibility-filtering verdicts as DROP |
| 2 | **`AncillaryVFFilter`** | ancestor / quoted / retweeted post is DROP → this post is removed too |
| 3 | `AncestorVideoFilter` | ancestor-video related |
| 4 | **`DedupConversationFilter`** | **keeps only the highest-scoring post per conversation** |
| 5 | `VideoCarouselFilter` | video-carousel related |

### 3.1 Conversation dedup: one slot per thread

`home-mixer/filters/dedup_conversation_filter.rs:19-36`:

```rust
let conversation_id = get_conversation_id(&candidate);  // smallest id among ancestors, i.e. the root post
if let Some((kept_idx, best_score)) = best_per_convo.get_mut(&conversation_id) {
    if score > *best_score { /* swap in the new one, remove the old */ }
    else { /* remove the new one */ }
}
```

**Implication**: if you fire off 5 posts in the same thread, at most 1 of them appears
in For You (the highest-scoring one). **A long thread does not win you more exposure
slots.**

### 3.2 Collateral removal

`AncillaryVFFilter`: if any one of the ancestor posts, the quoted post, or the
retweeted post is verdicted DROP, this post is removed as well.

**Implication**: quoting a violating post gets your own post killed alongside it. Same
for retweeting. **This is the easiest trap to fall into on the safety side.**

### 3.3 Two review standards: quoted posts are always checked at the stricter level

`home-mixer/candidate_hydrators/vf_candidate_hydrator.rs:67-106` splits candidates into
two batches and sends them to VF at **different safety levels**:

| What is sent for review | safety level | Strictness |
|---|---|---|
| in-network posts + **the original of a retweet** | `TimelineHome` | looser |
| out-of-network posts + **all ancestor posts** + **all quoted posts** | `TimelineHomeRecommendations` | **stricter** |

```rust
// vf_candidate_hydrator.rs:76-84
for &ancestor_id in &candidate.ancestors { oon_ids.push(ancestor_id); }
if let Some(quoted_id) = candidate.quoted_tweet_id { oon_ids.push(quoted_id); }
if let Some(retweeted_id) = candidate.retweeted_tweet_id { in_network_ids.push(retweeted_id); }
```

**Implication**: even when your own post is shown to your own followers (in-network),
**the post you quoted** is still reviewed at the stricter "recommendation" standard.
Quoting borderline content causes collateral problems more easily than posting it
directly.

Note that ancestor posts also always go through the strict tier, so **replying under a
deamplified post gets your reply killed along with the ancestor**.

---

## 4. Session-level dedup and the seen-post mechanism

Seen posts are handled twice (README `Filtering` section + `param.rs`):

- `ThunderSource` receives the seen list directly and does not return those posts at
  retrieval time
- other sources are not given the list; `PreviouslySeenPostsFilter` /
  `PreviouslySeenPostsBackupFilter` catch them instead

Served-post exclusion window: **10 minutes / 100 posts**
(`ExcludeServedTweetIdsDuration=10`, `ExcludeServedTweetIdsNumber=100`,
`param.rs:1280,1286`).

Cached post cap **750** (`MaxPostsToCache`, `param.rs:790`); Phoenix request cache TTL
**10800 seconds = 3 hours** (`param.rs:1219`).

---

## 5. The funnel, by order of magnitude

```
Thunder 1200 (in-network)
Phoenix 1000 + cold start 200 (out-of-network)
SimClusters ? (out-of-network)
Popular 500 (out-of-network)
        │  roughly 3000+ in total
        ▼
21 pre-scoring filters (48h / stranger replies and retweets / seen / mutes / subscriptions…)
        ▼
FairShareRankingFilter → cap 2800, trimmed proportionally per source
        ▼
Phoenix transformer scoring (candidates cannot see each other)
        ▼
vm-ranker recomputation: × author diversity × OON 0.75 + cold-start lift of 1 slot
        ▼
DPP diversity reranking (theta 0.65, affects at most the top 150)
        ▼
TopKScoreSelector takes top K
        ▼
VFFilter / AncillaryVFFilter (safety DROP)
DedupConversationFilter (one post per conversation)
        ▼
BlenderSelector blends in ads / Who to Follow / prompts
        ▼
Final For You
```

**Note that safety enforcement comes last**: a post can score very high, rank 3rd, and
then vanish because VF verdicts it DROP. Ranking and visibility are two independent
systems (README `Key Design Decisions` item 4).