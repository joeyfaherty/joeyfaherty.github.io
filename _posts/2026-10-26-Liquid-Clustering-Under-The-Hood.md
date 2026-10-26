---
layout: post
title: "Liquid Clustering in Databricks: What It Is, How It Works, When to Skip It"
date: 2026-10-26
categories: [databricks, delta-lake, data-engineering, performance, lakehouse]
---

# Liquid Clustering in Databricks: What It Is, How It Works, When to Skip It

<a href="/assets/images/2026-10-26-liquid-clustering-hero.png"><img src="/assets/images/2026-10-26-liquid-clustering-hero.png" alt="Liquid clustering cheat sheet: what it is, partitioning vs ZORDER vs liquid, when to use what, five mechanisms under the hood (layout in the log, Hilbert curve, min/max file skipping, ZCubes, key changes as metadata commits), code, compute cost and key takeaways" style="width:100%;height:auto;border-radius:8px"></a>
<p style="text-align:center;font-size:0.85em;margin-top:0.3em"><em>Click to open full size.</em></p>

Liquid clustering is a Delta Lake data layout technique that **replaces partitioning and `ZORDER`**. You name up to four clustering keys, Delta keeps rows with similar key values in the same files, and queries that filter on those keys skip the files they don't need. Unlike partitioning, you can change the keys later without rewriting existing data.

Databricks now recommends it for all new tables. This post covers what it gives you, how it does it underneath, and when something else is the better fit.

---

## What You Get

| Benefit | What it means in practice |
|---------|---------------------------|
| **Flexible keys** | `ALTER TABLE … CLUSTER BY` changes the keys. Existing files are not rewritten. |
| **Multi-column skipping** | Up to four keys, clustered together, so filters on any of them can skip files. |
| **Incremental maintenance** | `OPTIMIZE` rewrites only data that isn't clustered yet, not the whole table. |
| **No partition sizing** | No guessing a partition column that gives "not too many, not too few" directories. |
| **Fewer write conflicts** | Row-level concurrency lets concurrent writers touch the same files. |
| **Optional autopilot** | `CLUSTER BY AUTO` picks keys from query history on Unity Catalog managed tables. |

```sql
CREATE TABLE sales.orders (
  order_date  DATE,
  region      STRING,
  customer_id BIGINT,
  amount      DECIMAL(18,2)
)
CLUSTER BY (order_date, customer_id);

OPTIMIZE sales.orders;                                -- incremental recluster
ALTER TABLE sales.orders CLUSTER BY (region, customer_id);  -- change keys, no rewrite
ALTER TABLE sales.orders CLUSTER BY AUTO;             -- let Databricks choose (UC managed)
DESCRIBE DETAIL sales.orders;                         -- shows current clustering keys
```

---

## How It Works Underneath

Five mechanisms deliver those benefits. Each one is simple; together they remove the need for a physical directory layout.

### 1. The layout lives in the transaction log, not in folders

A partitioned table encodes its layout in **directory paths**. The path *is* the index, so changing the partition column means moving every file.

A clustered table has a flat set of files. The clustering keys are a **table property recorded in the Delta transaction log** (the `Clustering` and `DomainMetadata` table features). Changing the keys is a metadata commit: no file moves.

<pre class="mermaid">
flowchart LR
    subgraph P["Partitioned: layout = directory paths"]
        direction TB
        P1["order_date=2026-10-01/"] --> PF1["part-000.parquet"]
        P2["order_date=2026-10-02/"] --> PF2["part-000.parquet"]
        P3["order_date=2026-10-03/"] --> PF3["part-000.parquet"]
    end
    subgraph L["Liquid: layout = log metadata"]
        direction TB
        LOG["_delta_log<br/>clustering keys: order_date, customer_id<br/>per-file min/max stats"] --> LF["flat data files<br/>f001 · f002 · f003 · ..."]
    end
</pre>

### 2. A space-filling curve orders rows across several columns

To keep rows close on *several* columns at once, Delta maps each row's key values onto a single position along a **space-filling curve**, then sorts by that position and cuts the sorted stream into files. Delta Lake's default curve for liquid clustering is the **Hilbert curve**, which replaces the Z-order curve used by `ZORDER`.

The difference matters. Both curves visit every cell of the key space, but the Z-order curve makes **long jumps**, while the Hilbert curve only ever steps to a neighbouring cell:

<figure>
<svg viewBox="0 0 440 250" role="img" aria-label="Z-order curve with long jumps next to a Hilbert curve that only steps to neighbouring cells" style="max-width:520px;width:100%;height:auto;font-family:inherit">
  <g fill="none" stroke="#c9c2b4" stroke-width="1">
    <rect x="20" y="40" width="160" height="160"/>
    <path d="M60 40V200M100 40V200M140 40V200M20 80H180M20 120H180M20 160H180"/>
    <rect x="260" y="40" width="160" height="160"/>
    <path d="M300 40V200M340 40V200M380 40V200M260 80H420M260 120H420M260 160H420"/>
  </g>
  <polyline fill="none" stroke="#b8381f" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"
    points="40,60 80,60 40,100 80,100 120,60 160,60 120,100 160,100 40,140 80,140 40,180 80,180 120,140 160,140 120,180 160,180"/>
  <polyline fill="none" stroke="#1f5f8b" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"
    points="280,60 320,60 320,100 280,100 280,140 280,180 320,180 320,140 360,140 360,180 400,180 400,140 400,100 360,100 360,60 400,60"/>
  <g font-size="13" fill="currentColor">
    <text x="100" y="28" text-anchor="middle" font-weight="600">Z-order (ZORDER)</text>
    <text x="340" y="28" text-anchor="middle" font-weight="600">Hilbert (liquid clustering)</text>
    <text x="100" y="225" text-anchor="middle">diagonal jumps across the grid</text>
    <text x="340" y="225" text-anchor="middle">every step is to a neighbour</text>
    <text x="100" y="244" text-anchor="middle" font-size="11">x = key 1, y = key 2</text>
    <text x="340" y="244" text-anchor="middle" font-size="11">x = key 1, y = key 2</text>
  </g>
</svg>
<figcaption>A file is a run of consecutive positions on the curve. Fewer jumps means each file covers a tighter box of key values.</figcaption>
</figure>

Because a file is a contiguous stretch of the curve, fewer jumps means each file's rows fall in a **tighter range on every key**. That's what makes the next step work.

### 3. Data skipping uses per-file min/max statistics

Every file added to a Delta table carries statistics in the transaction log: row count, null counts, and **min and max values per column** (for the first 32 columns by default). At query time Delta compares the filter to each file's min/max range and never opens files that can't match.

Clustering doesn't add a new index. It makes the existing statistics **selective**, by shrinking each file's min/max range:

```
Unclustered (arrival order)          Clustered on customer_id
file   customer_id min..max          file   customer_id min..max
f001   3 ........... 9,998,112       f001   1 ........ 10,000
f002   1 ........... 9,999,870       f002   10,001 .... 20,000
f003   7 ........... 9,997,455       f003   20,001 .... 30,000

WHERE customer_id = 42               WHERE customer_id = 42
→ every range contains 42            → only f001's range contains 42
→ open every file                    → skip the rest
```

<pre class="mermaid">
sequenceDiagram
    participant Q as Query (WHERE customer_id = 42)
    participant L as Delta log
    participant S as Object storage
    Q->>L: list files + min/max stats
    L-->>Q: f001 [1..10000], f002 [10001..20000], ...
    Note over Q: keep files whose range can contain 42
    Q->>S: read f001 only
    S-->>Q: matching rows
</pre>

This is also why every clustering key needs statistics collected, and why complex types (struct, map, array) can't be keys.

### 4. Incremental clustering with ZCubes

`ZORDER` re-sorts all the data it's pointed at, every time. Liquid clustering avoids that with **ZCubes**: a ZCube is a group of files with Hilbert-clustered data produced by one `OPTIMIZE` run. Each clustered file is **tagged with its ZCube ID** in the Delta log. The next `OPTIMIZE` reads those tags and rewrites only files that aren't in a ZCube yet.

<pre class="mermaid">
flowchart LR
    subgraph T["Table files before OPTIMIZE"]
        direction TB
        Z1["ZCube A<br/>(tagged, clustered)"]
        Z2["ZCube B<br/>(tagged, clustered)"]
        U["new files<br/>(untagged, arrival order)"]
    end
    U -->|"OPTIMIZE picks only untagged files"| O["Hilbert sort<br/>+ rewrite"]
    O --> Z3["ZCube C<br/>(tagged, clustered)"]
    Z1 -.->|"left alone"| K["unchanged"]
    Z2 -.->|"left alone"| K
</pre>

The trade-off is deliberate: each ZCube is well clustered internally, but ZCubes overlap with each other on key ranges. Write cost stays low, at the price of a layout that's slightly less tight than a full re-sort. `OPTIMIZE … FULL` closes the gap by reclustering everything; use it after changing keys or enabling clustering on an existing table.

Writes can also cluster data as it lands. On Databricks, `INSERT INTO`, CTAS, `COPY INTO` and batch appends cluster on write once a transaction passes a size threshold; streaming writes need `spark.databricks.delta.liquid.eagerClustering.streaming.enabled = true`. Anything smaller lands unclustered and waits for `OPTIMIZE`.

### 5. Changing keys is a metadata commit

Because the layout is a property in the log (mechanism 1) and maintenance is incremental (mechanism 4), changing keys is cheap:

<pre class="mermaid">
sequenceDiagram
    participant U as You
    participant L as Delta log
    participant O as OPTIMIZE
    U->>L: ALTER TABLE ... CLUSTER BY (region, customer_id)
    Note over L: new commit: clustering keys updated<br/>no data files touched
    O->>L: next run reads new keys
    O->>O: clusters new and unclustered files on (region, customer_id)
    Note over O: old files keep their old layout<br/>until OPTIMIZE FULL
</pre>

The catch: old files stay clustered on the old keys until you run `OPTIMIZE … FULL`. Queries stay correct either way; only skipping effectiveness changes.

### Bonus: row-level concurrency

On Databricks, clustered tables get row-level concurrency: with deletion vectors and row tracking enabled, conflicting writes are detected at the **row** level rather than the file level. Two writers updating different rows in the same file no longer conflict. Turn off either feature and you lose this.

---

## How the Pieces Fit

<pre class="mermaid">
flowchart TD
    W["Writes<br/>(batch, streaming, MERGE)"] -->|"above size threshold"| CW["cluster on write"]
    W -->|"below threshold"| UF["unclustered files"]
    CW --> TBL["Delta table<br/>keys + per-file stats in the log"]
    UF --> TBL
    TBL --> OPT["OPTIMIZE (scheduled or predictive)<br/>rewrites only untagged files → new ZCube"]
    OPT --> TBL
    TBL --> R["Reads<br/>min/max stats skip files"]
    AUTO["CLUSTER BY AUTO<br/>(UC managed tables)"] -.->|"picks / changes keys from query history"| TBL
</pre>

---

## When Something Else Fits Better

Liquid clustering is the default choice for new tables, but not the only one.

| Situation | Better fit | Why |
|-----------|-----------|-----|
| **Small tables, or queries that mostly scan everything** | No layout at all | Skipping only helps when filters can rule out files. |
| **No stable filter columns** | No layout, or revisit later with `CLUSTER BY AUTO` | Keys chosen by guesswork don't skip anything. |
| **Iceberg tables outside Databricks** | Iceberg sort orders / Z-order rewrites | Liquid clustering is a Delta Lake feature; Iceberg engines use their own layout tools. |
| **The workload is built around the partition column, or constrained from outside Databricks** | Partitioning + `ZORDER` | See below. |

Two hard rules: liquid clustering **can't be combined** with partitioning or `ZORDER` on the same table, and keys are limited to **four** columns. Highly correlated columns (say, `order_date` and `order_timestamp`) only need one key.

### When partition + ZORDER still wins

| Case | Why partition + `ZORDER` wins |
|------|-------------------------------|
| **Whole-partition lifecycle operations** (drop old days, overwrite a day with `replaceWhere`) | When the condition matches whole partitions, Delta removes or swaps those files in the log, with no data rewrite. On a clustered table the same delete or overwrite may rewrite files or write deletion vectors, depending on how file ranges line up with the condition. |
| **Partitions stop changing once written** (yesterday's data never changes) | Run `ZORDER` once per partition when it closes, then never again. A bounded, one-off cost, and `ZORDER`'s weakness (re-sorting repeatedly) never comes up. |
| **Readers outside Databricks rely on folder-based pruning, or can't read the newer protocol** | Older Hive-style engines only skip data by directory (`date=…/`). Clustered tables need writer v7 and (on Databricks) reader v3, and the protocol can't be downgraded. |
| **Pinned older runtimes** (or OSS Delta below 3.1) | Liquid clustering needs a recent runtime; enabling it on an existing OSS table needs Delta 3.3+. `ZORDER` works almost everywhere. |
| **A stable setup that already works** (always date + one column, access patterns never change) | Migrating costs a protocol upgrade, a full recluster and re-testing jobs. Changeable keys are worth nothing if you never change them. |

What these cases share: the workload is **built around the partition column**, or **something outside Databricks constrains the table**. Without those constraints, liquid clustering is the better default.

<pre class="mermaid">
flowchart TD
    A{"Do queries filter on<br/>stable columns?"} -->|no| N["No layout<br/>(or try CLUSTER BY AUTO later)"]
    A -->|yes| B{"Can every reader and writer<br/>handle the clustering protocol?"}
    B -->|no| Z["Stay on partitioning / ZORDER<br/>until they're upgraded"]
    B -->|yes| P{"Built around whole-partition<br/>drops or overwrites?"}
    P -->|yes| PZ["Partition by that column<br/>ZORDER once per closed partition"]
    P -->|no| C{"New table?"}
    C -->|yes| LC["CREATE TABLE ... CLUSTER BY<br/>or CLUSTER BY AUTO"]
    C -->|no, existing| M["ALTER TABLE ... CLUSTER BY<br/>then OPTIMIZE FULL"]
</pre>

---

## What It Costs to Run

Liquid clustering is not free: the rows have to be sorted along the Hilbert curve somewhere, and that takes compute in one of three places.

1. **Clustering on write.** The writing job does the extra sort when a transaction passes the size threshold. Write jobs use somewhat more CPU.
2. **`OPTIMIZE` jobs.** Small writes, and streams without the eager-clustering config, land unclustered. A scheduled `OPTIMIZE` on your own compute clusters them later.
3. **Predictive optimization / `CLUSTER BY AUTO`.** Databricks runs `OPTIMIZE` for you on billed serverless compute. `CLUSTER BY AUTO` requires predictive optimization.

Two things keep this in perspective:

- **It costs speed, not correctness.** If clustering falls behind, queries still return the right rows; they just skip fewer files until `OPTIMIZE` catches up.
- **`ZORDER` costs compute too, usually more.** It's also an `OPTIMIZE` job, and it re-sorts all the data it targets every run. Only plain partitioning (without `ZORDER`) has no ongoing maintenance compute, because its layout is fixed when data is written, but it only skips on the partition column.

| Layout | Compute when writing | Ongoing maintenance |
|--------|----------------------|---------------------|
| **Partitioning only** | Small: rows are split by partition on write | None, apart from compacting small files |
| **Partition + `ZORDER`** | Same as above | `OPTIMIZE … ZORDER BY` fully re-sorts each targeted partition: run it once per closed partition, or keep re-running it |
| **Liquid clustering** | Extra sort when clustering on write | Incremental `OPTIMIZE`, by you or by predictive optimization on billed serverless compute |

---

## Checking It Works

1. `DESCRIBE DETAIL <table>` shows the clustering keys.
2. Run your top queries before and after, and compare **files read** and **files pruned** in the query profile.
3. Keep `OPTIMIZE` running (every one to two hours for busy tables, or let predictive optimization do it, not both).

---

## Sources

- [Use liquid clustering for tables](https://docs.databricks.com/aws/en/tables/clustering), Databricks documentation
- [Use liquid clustering for Delta tables](https://docs.delta.io/latest/delta-clustering.html), Delta Lake documentation
- [Delta Lake 3.2 release](https://delta.io/blog/delta-lake-3-2/), Delta Lake blog (Hilbert curve and ZCubes)
- [Delta transaction log protocol](https://github.com/delta-io/delta/blob/master/PROTOCOL.md) (per-file statistics, table features)
