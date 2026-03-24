---
layout: post
title: "Spark Structured Streaming: writeStream vs foreachBatch vs Flink — How to Read a Source Once and Write Multiple Outputs"
comments: true
---

## The Multi-Sink Streaming Problem

In production streaming pipelines you almost always need to:

1. Read a source stream **once** (Kafka, Kinesis, etc.)
2. Parse and transform that stream **once**
3. Write results to **multiple downstream sinks**

This pattern appears everywhere:

- **Event-driven architectures** — a single domain event fans out to multiple bounded contexts
- **Log analytics** — raw application logs are split into request traces, error events, and performance metrics
- **Observability pipelines** — a unified telemetry stream is demultiplexed into logs, metrics, and traces
- **Event modeling platforms** — a generic event envelope is unpacked into strongly-typed analytical tables

The desire is simple: **parse once, reuse the result, write N outputs.** The reality in Spark Structured Streaming is far more nuanced than most engineers expect.

---

## The Example: A Single Event, Multiple Tables

Consider a web platform emitting application log events to Kafka. Each event is a rich, nested JSON structure:

```json
{
  "eventId": "evt_123",
  "timestamp": "2026-03-12T10:12:00Z",
  "user": {
    "userId": "u42",
    "country": "IE"
  },
  "request": {
    "endpoint": "/checkout",
    "latency_ms": 120,
    "status_code": 500
  },
  "errors": [
    {
      "errorCode": "DB_TIMEOUT",
      "severity": "critical"
    }
  ]
}
```

From this **single event stream**, the platform must produce three analytical tables:

| Target Table           | Extracted Fields                                          |
|------------------------|-----------------------------------------------------------|
| `request_logs`         | `eventId`, `timestamp`, `userId`, `endpoint`, `status_code` |
| `error_events`         | `eventId`, `timestamp`, `userId`, `errorCode`, `severity`   |
| `performance_metrics`  | `eventId`, `timestamp`, `endpoint`, `latency_ms`            |

The JSON parsing, schema validation, and flattening are **computationally expensive** — we absolutely must not repeat that work per sink.

---

## Spark Structured Streaming Architecture

Before comparing approaches, let's ground ourselves in how Spark Structured Streaming actually works.

### Micro-Batch Execution

Spark Structured Streaming is — at its core — a **micro-batch engine**. Each trigger interval, Spark:

1. Reads new offsets from the source (Kafka offsets, file listings, etc.)
2. Constructs a **batch DataFrame** representing the new data
3. Runs the full Catalyst optimization pipeline (logical plan → optimized logical plan → physical plan)
4. Executes the physical plan as a standard Spark job
5. Commits offsets to the **checkpoint directory**
6. Repeats

<div class="mermaid" markdown="0">
flowchart TD
    A["Trigger Fires"] --> B["Read New Offsets from Source"]
    B --> C["Construct Micro-Batch DataFrame"]
    C --> D["Catalyst: Logical Plan"]
    D --> E["Catalyst: Optimized Logical Plan"]
    E --> F["Catalyst: Physical Plan"]
    F --> G["Execute Spark Job on Executors"]
    G --> H["Commit Offsets to Checkpoint"]
    H --> A
</div>

### The Critical Design Point

**Each `writeStream` call creates an independent streaming query.** Each streaming query has its own:

- Catalyst logical plan
- Physical execution DAG
- Checkpoint directory
- Offset tracking
- Fault recovery boundary

This is not a limitation — it is a **deliberate architectural decision** for fault tolerance. But it has profound implications for multi-sink pipelines.

---

## Catalyst Planning and Streaming DAGs

When you call `.writeStream.start()`, Spark constructs a **complete, self-contained execution graph** for that query. Let's trace through what Catalyst does.

### Plan Compilation per Query

```
Streaming Query = Source -> Transformations -> Sink
                  |
            Logical Plan (unresolved)
                  |
            Analyzed Logical Plan (resolved references)
                  |
            Optimized Logical Plan (predicate pushdown, column pruning, etc.)
                  |
            Physical Plan (chosen strategies, exchange nodes)
                  |
            Executed as Spark Jobs per micro-batch
```

**Each streaming query goes through this entire pipeline independently.** Even if two queries share the exact same source and transformations in your Scala/Python code, Spark does not detect or exploit that overlap.

<div class="mermaid" markdown="0">
flowchart TD
    subgraph Query1["Streaming Query 1 - request_logs"]
        S1["Kafka Source"] --> P1["Parse JSON"] --> T1["Flatten Event"] --> W1["Write to request_logs"]
    end
    subgraph Query2["Streaming Query 2 - error_events"]
        S2["Kafka Source"] --> P2["Parse JSON"] --> T2["Flatten Event"] --> W2["Write to error_events"]
    end
    subgraph Query3["Streaming Query 3 - performance_metrics"]
        S3["Kafka Source"] --> P3["Parse JSON"] --> T3["Flatten Event"] --> W3["Write to performance_metrics"]
    end
</div>

Three queries. Three full DAGs. **Three reads from Kafka. Three JSON parse passes. Three flatten operations.** The upstream computation is fully duplicated.

---

## Approach 1: Multiple writeStream Queries (The Naive Pattern)

This is the first thing most engineers try:

```scala
val raw = spark.readStream
  .format("kafka")
  .option("subscribe", "app-events")
  .load()

val parsed = raw
  .select(from_json(col("value").cast("string"), eventSchema).as("event"))
  .select("event.*")

// Flatten nested structs
val enriched = parsed
  .withColumn("userId", col("user.userId"))
  .withColumn("endpoint", col("request.endpoint"))
  .withColumn("latency_ms", col("request.latency_ms"))
  .withColumn("status_code", col("request.status_code"))

// 3 independent streaming queries
val q1 = enriched
  .select("eventId", "timestamp", "userId", "endpoint", "status_code")
  .writeStream.format("delta").option("checkpointLocation", "/cp/request_logs")
  .start("/data/request_logs")

val q2 = enriched
  .select("eventId", "timestamp", "userId")
  .withColumn("errors", explode(col("errors")))
  .select("eventId", "timestamp", "userId",
          col("errors.errorCode"), col("errors.severity"))
  .writeStream.format("delta").option("checkpointLocation", "/cp/error_events")
  .start("/data/error_events")

val q3 = enriched
  .select("eventId", "timestamp", "endpoint", "latency_ms")
  .writeStream.format("delta").option("checkpointLocation", "/cp/perf_metrics")
  .start("/data/performance_metrics")

spark.streams.awaitAnyTermination()
```

### Why This Is Expensive

Despite sharing the `val enriched` reference in your Scala code, **the JVM object graph is irrelevant to Spark's execution model**. Spark operates on **plans**, not on JVM object identity.

When `q1.start()` is called, Spark walks the DataFrame lineage from `enriched` back to the Kafka source and constructs a complete, independent plan. When `q2.start()` is called, it does the exact same thing — a second complete plan rooted at the same Kafka source. And again for `q3`.

<div class="mermaid" markdown="0">
flowchart LR
    subgraph Cluster["Spark Cluster - 3x Resource Consumption"]
        direction TB
        subgraph Q1["Query 1"]
            K1["Kafka Read 1"] --> P1["Parse JSON 1"] --> F1["Flatten 1"] --> S1["request_logs"]
        end
        subgraph Q2["Query 2"]
            K2["Kafka Read 2"] --> P2["Parse JSON 2"] --> F2["Flatten 2"] --> S2["error_events"]
        end
        subgraph Q3["Query 3"]
            K3["Kafka Read 3"] --> P3["Parse JSON 3"] --> F3["Flatten 3"] --> S3["perf_metrics"]
        end
    end
</div>

**The result:**

| Resource              | Expected | Actual (3 writeStreams) |
|-----------------------|----------|------------------------|
| Kafka reads           | 1x       | 3x                     |
| JSON parsing          | 1x       | 3x                     |
| Flatten / enrichment  | 1x       | 3x                     |
| Cluster memory        | 1x       | ~3x                    |
| Checkpoint storage    | shared   | 3 independent dirs     |

At scale — say 500K events/second with complex Avro/JSON deserialization — this **triples your compute cost** and **triples your Kafka consumer load** for no reason.

### Why Spark Cannot Share State Across Queries

The reason is **fault tolerance correctness**. Each streaming query maintains:

- **Its own offset log** — which Kafka offsets have been consumed
- **Its own commit log** — which micro-batches have been committed to the sink
- **Its own state store** — for stateful operations (aggregations, dedup, sessionization)

If queries shared a DAG, a failure in one query's sink write would require rolling back **all** queries to a consistent checkpoint. This would couple the fault domains of unrelated sinks. Spark's designers explicitly chose **query isolation** to avoid cascading failures.

---

## Spark Checkpointing and Exactly-Once Guarantees

Understanding why shared execution is impossible requires understanding the checkpoint contract.

### The Checkpoint Directory Structure

```
/checkpoint/query_1/
├── offsets/          # Planned offsets per micro-batch
│   ├── 0            # {kafka_offsets: {partition_0: 100}}
│   ├── 1            # {kafka_offsets: {partition_0: 200}}
│   └── 2
├── commits/          # Confirmed committed batches
│   ├── 0
│   └── 1
├── metadata          # Query metadata
└── state/            # State store (if stateful)
```

### The Exactly-Once Contract

1. **Pre-commit**: Spark writes the batch's offset range to `offsets/N`
2. **Execution**: The micro-batch runs, writing to the sink
3. **Post-commit**: Spark writes `commits/N` to confirm

On recovery, Spark checks: *"Is there an offset file without a matching commit file?"* If yes, it **replays that batch**. The sink must be **idempotent** or support **transactional writes** (e.g., Delta Lake) for this to be exactly-once rather than at-least-once.

**If two queries shared offset tracking, a failure in one sink's commit would force a replay that also rewrites to the other sink** — breaking exactly-once for the successful sink. This is why Spark requires independent checkpoint directories per query.

---

## Approach 2: Persisting Intermediate DataFrames

A common misconception:

```scala
val parsed = transform(stream).persist()  // DOES NOT HELP
```

### Why `.persist()` / `.cache()` Fails for Streaming

In batch Spark, `.persist()` materializes a DataFrame in memory/disk and subsequent actions reuse it. In Structured Streaming, this does not work as expected because:

1. **Streaming DataFrames are not materialized** — they represent a *continuous query definition*, not a fixed dataset
2. **Each micro-batch produces new data** — there is nothing stable to cache across triggers
3. **Persist applies per-batch** — it caches the current micro-batch's data, but each `writeStream` still creates its own query with its own DAG, so the persist hint is duplicated, not shared
4. **Memory pressure** — caching streaming data accumulates unbounded memory usage if not carefully managed

**`.persist()` on a streaming DataFrame is a no-op in terms of cross-query sharing.** It is only useful within a single query's transformations.

---

## Approach 3: foreachBatch — The Correct Spark Pattern

The `foreachBatch` API is the **sanctioned escape hatch** for multi-sink streaming in Spark:

```scala
val raw = spark.readStream
  .format("kafka")
  .option("subscribe", "app-events")
  .load()

raw.writeStream
  .foreachBatch { (batchDF: DataFrame, batchId: Long) =>

    // ── Parse ONCE ──────────────────────────
    val parsed = batchDF
      .select(from_json(col("value").cast("string"), eventSchema).as("event"))
      .select("event.*")

    val enriched = parsed
      .withColumn("userId", col("user.userId"))
      .withColumn("endpoint", col("request.endpoint"))
      .withColumn("latency_ms", col("request.latency_ms"))
      .withColumn("status_code", col("request.status_code"))
      .persist()  // NOW persist works — this is a batch DF

    // ── Write to 3 sinks from the SAME parsed batch ──
    enriched
      .select("eventId", "timestamp", "userId", "endpoint", "status_code")
      .write.format("delta").mode("append")
      .save("/data/request_logs")

    enriched
      .select("eventId", "timestamp", "userId")
      .withColumn("errors_flat", explode(col("errors")))
      .select("eventId", "timestamp", "userId",
              col("errors_flat.errorCode"), col("errors_flat.severity"))
      .write.format("delta").mode("append")
      .save("/data/error_events")

    enriched
      .select("eventId", "timestamp", "endpoint", "latency_ms")
      .write.format("delta").mode("append")
      .save("/data/performance_metrics")

    enriched.unpersist()
  }
  .option("checkpointLocation", "/cp/multi_sink_pipeline")
  .start()
```

### Why foreachBatch Works

Inside `foreachBatch`, the `batchDF` is a **static (batch) DataFrame** — not a streaming DataFrame. This changes everything:

<div class="mermaid" markdown="0">
flowchart TD
    K["Kafka Read - ONCE per micro-batch"] --> P["Parse JSON - ONCE"]
    P --> E["Flatten and Enrich - ONCE"]
    E --> Cache["persist in memory"]
    Cache --> W1["Write request_logs"]
    Cache --> W2["Write error_events"]
    Cache --> W3["Write perf_metrics"]
    W3 --> Un["unpersist"]
</div>

| Benefit                    | Detail                                                       |
|----------------------------|--------------------------------------------------------------|
| **Single Kafka read**      | One streaming query = one consumer group = one offset tracker |
| **Single parse**           | JSON deserialization happens once per micro-batch             |
| **Shared DataFrame**       | `.persist()` works because `batchDF` is a batch DataFrame    |
| **Single checkpoint**      | One checkpoint directory for the entire pipeline             |
| **Standard batch writes**  | Inside `foreachBatch`, you use `.write` (batch API), not `.writeStream` |

### foreachBatch Limitations

`foreachBatch` is a pragmatic solution, but it has real tradeoffs:

1. **No end-to-end exactly-once across sinks** — if the second `.write` fails, the first `.write` has already committed. On replay (from checkpoint), the first sink gets **duplicates**. You must make sinks **idempotent** (e.g., Delta Lake `MERGE`, or write with a deterministic path based on `batchId`).

2. **Sequential sink writes** — within `foreachBatch`, writes execute **sequentially by default**. You can parallelize them with threads, but you own the complexity:

   ```scala
   import scala.concurrent.{Future, Await}
   import scala.concurrent.duration._
   import scala.concurrent.ExecutionContext.Implicits.global

   val f1 = Future { enriched.select(...).write.save("/data/request_logs") }
   val f2 = Future { enriched.select(...).write.save("/data/error_events") }
   val f3 = Future { enriched.select(...).write.save("/data/perf_metrics") }

   Await.result(Future.sequence(Seq(f1, f2, f3)), 5.minutes)
   ```

3. **Micro-batch latency** — you're still bound by micro-batch trigger intervals. End-to-end latency is typically seconds, not milliseconds.

4. **No streaming state** — watermarks, session windows, and streaming aggregations **do not compose well** inside `foreachBatch`. State management is tied to the outer query, and the batch DataFrame inside is stateless.

---

## Apache Flink: Multi-Sink Streaming Done Right

Flink solves the multi-sink problem **architecturally** — it doesn't need workarounds because its execution model natively supports DAG fan-out.

### Flink's Execution Model

Flink processes data as a **continuous dataflow graph**. There are no micro-batches. Each record flows through a DAG of operators, record-by-record (or in small network buffers for throughput). Crucially:

- The DAG is a **single, unified execution graph**
- A single operator's output can be **routed to multiple downstream operators**
- **No re-reading of the source** is required for fan-out — it is a simple edge split in the DAG

<div class="mermaid" markdown="0">
flowchart LR
    K["Kafka Source - read ONCE"] --> P["Parse JSON - ONCE per record"]
    P --> R["Route / Split"]
    R -->|"request fields"| S1["Iceberg: request_logs"]
    R -->|"error fields"| S2["Iceberg: error_events"]
    R -->|"perf fields"| S3["Iceberg: performance_metrics"]
</div>

### Flink Code: Side Outputs for Fan-Out

Flink provides **side outputs** (`OutputTag`) for elegant fan-out from a single operator:

```java
// Define output tags
final OutputTag<RequestLog> requestTag =
    new OutputTag<RequestLog>("requests") {};
final OutputTag<ErrorEvent> errorTag =
    new OutputTag<ErrorEvent>("errors") {};

// Main stream — parse once
SingleOutputStreamOperator<PerformanceMetric> mainStream = env
    .addSource(new FlinkKafkaConsumer<>("app-events", ...))
    .process(new ProcessFunction<String, PerformanceMetric>() {
        @Override
        public void processElement(String event, Context ctx,
                                   Collector<PerformanceMetric> out) {
            AppEvent parsed = parse(event);  // PARSE ONCE

            // Side output: request logs
            ctx.output(requestTag, extractRequestLog(parsed));

            // Side output: error events
            for (ErrorInfo err : parsed.getErrors()) {
                ctx.output(errorTag, extractErrorEvent(parsed, err));
            }

            // Main output: performance metrics
            out.collect(extractPerformanceMetric(parsed));
        }
    });

// Retrieve side outputs
DataStream<RequestLog> requestLogs = mainStream.getSideOutput(requestTag);
DataStream<ErrorEvent> errorEvents = mainStream.getSideOutput(errorTag);

// Sink each stream
requestLogs.sinkTo(icebergSink("request_logs"));
errorEvents.sinkTo(icebergSink("error_events"));
mainStream.sinkTo(icebergSink("performance_metrics"));

env.execute("multi-sink-pipeline");
```

**One Kafka read. One parse. Three sinks. Zero recomputation.** This is not a workaround — it is the intended execution model.

### Flink Checkpointing and Exactly-Once

Flink achieves exactly-once semantics through **distributed snapshots** based on the Chandy-Lamport algorithm.

#### Checkpoint Barrier Flow

<div class="mermaid" markdown="0">
flowchart LR
    JM["JobManager - Checkpoint Coordinator"] -->|"inject barrier"| KS["Kafka Source"]
    KS -->|"barrier flows with data"| P["Parse Operator"]
    P -->|"barrier"| R["Route / Split"]
    R -->|"barrier"| S1["Sink 1"]
    R -->|"barrier"| S2["Sink 2"]
    R -->|"barrier"| S3["Sink 3"]
    S1 -->|"ack"| JM
    S2 -->|"ack"| JM
    S3 -->|"ack"| JM
</div>

The process works as follows:

1. **Barrier Injection** — The JobManager periodically injects **checkpoint barriers** into the source streams. These are special markers that flow through the DAG alongside regular records.

2. **Barrier Alignment** — When an operator receives a barrier on one input channel, it **blocks that channel** and continues processing the other channels until all input barriers arrive. This ensures that the operator's state reflects exactly the records before the barrier.

3. **State Snapshot** — Once all barriers are aligned, the operator **snapshots its state** to durable storage (RocksDB + remote checkpoint storage like S3/HDFS).

4. **Barrier Propagation** — The operator forwards the barrier downstream. This cascades through the entire DAG.

5. **Sink Pre-Commit** — Sinks that support two-phase commit (e.g., Kafka, Iceberg) enter a **pre-commit** state when they receive a barrier.

6. **Checkpoint Completion** — When the JobManager receives acknowledgements from **all** operators (including all sinks), the checkpoint is marked **complete**. Only then are sink transactions committed.

**This is the key difference:** Flink's checkpoint is a **global, atomic snapshot across the entire DAG**, including all sinks. If any sink fails to acknowledge, the entire checkpoint fails and the pipeline rolls back to the previous consistent state. This gives you **exactly-once across all sinks simultaneously** — something `foreachBatch` fundamentally cannot guarantee.

#### State Backend

Flink operators can maintain **keyed state** and **operator state** that is automatically included in checkpoints:

```java
// Keyed state example — survives failures
ValueState<Long> countState = getRuntimeContext()
    .getState(new ValueStateDescriptor<>("count", Long.class));
```

State is stored in a pluggable backend:

| Backend              | Storage    | Use Case                          |
|----------------------|------------|-----------------------------------|
| `HashMapStateBackend`| JVM Heap   | Small state, low latency          |
| `EmbeddedRocksDBStateBackend` | RocksDB (disk) | Large state, production workloads |

Both backends write **incremental snapshots** to remote storage during checkpoints, enabling fast recovery.

---

## Flink + Iceberg: The Production Stack

Apache Iceberg is a natural companion to Flink for multi-sink streaming. Here's why:

### Write-Ahead-Commit Protocol (WAP)

Flink's Iceberg sink implements a **two-phase commit protocol** tied to Flink's checkpointing:

<div class="mermaid" markdown="0">
sequenceDiagram
    participant JM as JobManager
    participant W as Flink Sink Writer
    participant IC as Iceberg Catalog
    JM->>W: Checkpoint Barrier arrives
    W->>W: Flush current data files to storage
    W->>W: Record file metadata
    W-->>JM: Acknowledge barrier pre-commit
    JM->>JM: All operators acknowledged
    JM->>W: Notify checkpoint complete
    W->>IC: Commit snapshot atomic metadata swap
    IC-->>W: Commit confirmed
</div>

1. **During normal processing**, the Flink Iceberg writer buffers records and writes Parquet/ORC data files to object storage
2. **On checkpoint barrier**, the writer flushes all pending data files and records their metadata — but does **not** commit to the Iceberg catalog yet
3. **On checkpoint completion** (all operators succeeded), the writer atomically commits a new Iceberg **snapshot** that includes the flushed files
4. **On failure**, uncommitted data files are orphaned and cleaned up — no partial data is ever visible to readers

### Why Flink + Iceberg Excels

| Capability                       | Benefit                                                    |
|----------------------------------|------------------------------------------------------------|
| **Atomic multi-table commits**   | Checkpoint spans all sinks — consistent point-in-time view |
| **Hidden partitioning**          | Iceberg handles partition evolution without rewriting queries |
| **Schema evolution**             | Add/rename/drop columns without breaking consumers         |
| **Time travel**                  | Query any historical snapshot for debugging or audit        |
| **Compaction**                   | Flink jobs can run async compaction to merge small files    |
| **Row-level deletes**            | Equality/position delete files enable CDC without rewrites |

### Flink SQL Example

```sql
CREATE TABLE request_logs (
    eventId STRING,
    ts TIMESTAMP(3),
    userId STRING,
    endpoint STRING,
    status_code INT
) WITH (
    'connector' = 'iceberg',
    'catalog-name' = 'prod_catalog',
    'catalog-type' = 'hive',
    'warehouse' = 's3://lake/warehouse'
);

INSERT INTO request_logs
SELECT eventId, ts, userId, endpoint, status_code
FROM parsed_events;
```

Multiple `INSERT INTO` statements from the same parsed source in a single Flink job — **zero recomputation**.

---

## Spark vs Flink: Detailed Comparison

| Feature                              | Spark Structured Streaming                             | Apache Flink                                        |
|--------------------------------------|--------------------------------------------------------|-----------------------------------------------------|
| **Execution model**                  | Micro-batch (or experimental continuous mode)          | True record-at-a-time streaming                     |
| **Multi-sink support**               | Workaround via `foreachBatch`                          | Native DAG fan-out with side outputs                |
| **Source reads for N sinks**         | N reads (with `writeStream`) / 1 read (`foreachBatch`) | Always 1 read                                       |
| **DAG reuse across sinks**           | Not possible across queries                            | Native — single unified DAG                         |
| **Exactly-once scope**               | Per-query (sink-level idempotence required)            | Global across all sinks via distributed checkpoints |
| **End-to-end latency**               | Seconds (micro-batch trigger)                          | Milliseconds (record-at-a-time)                     |
| **State management**                 | State store per query (HDFS/RocksDB)                   | Keyed state + operator state with incremental checkpoints |
| **Checkpoint coordination**          | Per-query offset/commit logs                           | Global Chandy-Lamport barriers across entire DAG    |
| **Backpressure handling**            | Rate limiting at source                                | Natural TCP-style backpressure through network stack |
| **Operational complexity**           | Lower (runs on existing Spark clusters)                | Higher (dedicated Flink cluster, ZooKeeper/K8s)     |
| **Batch + streaming unification**    | Strong (same DataFrame API)                            | Improving (DataStream + Table API convergence)      |
| **Ecosystem maturity**               | Massive (Delta Lake, Unity Catalog, Databricks)        | Growing (Iceberg, Paimon, AWS Managed Flink)        |

---

## Recommended Spark Architecture: foreachBatch Multi-Sink

If you are committed to Spark, the recommended production architecture is:

<div class="mermaid" markdown="0">
flowchart TD
    K["Kafka Consumer Group - single read"] --> FB["foreachBatch - per micro-batch trigger"]
    FB --> Parse["Parse JSON / Avro - ONCE"]
    Parse --> Enrich["Flatten, Validate, Enrich - ONCE"]
    Enrich --> Persist["persist"]
    Persist --> W1["Delta Lake: request_logs"]
    Persist --> W2["Delta Lake: error_events"]
    Persist --> W3["Delta Lake: performance_metrics"]
    W3 --> UP["unpersist"]
</div>

**Key implementation details:**

1. **Use Delta Lake or Iceberg sinks** — both support idempotent writes, which you need because `foreachBatch` replays on failure
2. **Persist the enriched DataFrame** — this is a batch DF inside `foreachBatch`, so `.persist()` actually works
3. **Consider parallel writes** — use `Future`-based concurrency for independent sink writes to reduce total batch time
4. **Use `batchId` for idempotency** — pass `batchId` to your write path to deduplicate on replay

   ```scala
   enriched
     .withColumn("_batch_id", lit(batchId))
     .write.format("delta").mode("append")
     .save("/data/request_logs")
   ```

5. **Monitor micro-batch duration** — if your batch time exceeds your trigger interval, you have a throughput problem. Scale executors or optimize your parse logic.

---

## When to Choose What

<div class="mermaid" markdown="0">
flowchart TD
    Start["Multi-Sink Streaming Requirement"] --> Q1{"Existing Spark infrastructure?"}
    Q1 -->|"Yes"| Q2{"Latency requirement?"}
    Q1 -->|"No / Greenfield"| Flink["Apache Flink - Native fan-out, ms latency"]
    Q2 -->|"Seconds OK"| FBatch["Spark foreachBatch - Single read, Parallel writes"]
    Q2 -->|"Sub-second needed"| Q3{"Can invest in Flink ops?"}
    Q3 -->|"Yes"| Flink
    Q3 -->|"No"| FBatch2["Spark foreachBatch with short intervals"]
</div>

---

## Summary

| Approach                        | Source Reads | Parse Cost | Exactly-Once Scope   | Complexity |
|---------------------------------|-------------|------------|----------------------|------------|
| Spark: multiple `writeStream`   | N times     | N times    | Per-query            | Low        |
| Spark: `foreachBatch`           | 1 time      | 1 time     | Per-sink (idempotent)| Medium     |
| Flink: native DAG fan-out      | 1 time      | 1 time     | Global (all sinks)   | Higher     |

**The takeaway:**

- If you are on Spark, **always use `foreachBatch` for multi-sink pipelines**. Multiple `writeStream` calls silently multiply your compute and I/O costs.
- If you are building a new streaming platform, **Flink's architecture is purpose-built for fan-out**. Combined with Iceberg, you get atomic multi-table commits, schema evolution, and millisecond latency — capabilities that Spark's micro-batch model cannot match.
- `foreachBatch` is a clever workaround within a batch-oriented execution engine. Flink's approach is not a workaround — it's the fundamental design.

Choose your tool based on your team's operational maturity, latency requirements, and existing infrastructure — but understand the architectural tradeoffs deeply before you commit.

