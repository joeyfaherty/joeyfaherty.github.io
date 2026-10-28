---
layout: post
title: "Is My Spark App Over-Provisioned? Core Busyness and Peak Memory (Spark App Doctor, Part 1)"
date: 2026-10-28
categories: [spark, performance, data-engineering]
---

# Is My Spark App Over-Provisioned? Core Busyness and Peak Memory (Spark App Doctor, Part 1)

<a href="/assets/images/2026-10-28-spark-over-provisioned-hero.png"><img src="/assets/images/2026-10-28-spark-over-provisioned-hero.png" alt="Spark over-provisioning cheat sheet: the two ratios (slot utilisation and peak memory headroom), where each lives in the Spark UI and the REST API, how executor memory is laid out, three shapes of idle time, a verdict matrix for what to cut, the measuring script, and common mistakes" style="width:100%;height:auto;border-radius:8px"></a>
<p style="text-align:center;font-size:0.85em;margin-top:0.3em"><em>Click to open full size.</em></p>

Two ratios tell you whether a Spark app is over-provisioned. How much of the core time you paid for ran tasks, and how much of the memory you asked for did the executors actually touch. Both are already recorded by Spark, in the UI and in the REST API, and you can compute them for any finished app in a few seconds.

This is part 1 of a three-part series on judging a Spark app from its own metrics:

| Part | Lens | Question |
|------|------|----------|
| **1 (this post)** | **Waste** | Did we pay for resources we didn't use? |
| **2** | **Pathology** | Why is it slow, and would more executors even help? |
| **3** | **Regression** | Is it getting worse, and how do I check this automatically? |

---

## The Scenario

A nightly batch job that nobody has looked at since it was first sized.

| Assumption | Value |
|------------|-------|
| **Executors** | 40, fixed (dynamic allocation off) |
| **Per executor** | 4 cores, `spark.executor.memory=16g` |
| **Wall time** | 60 min |
| **Allocated core time** | 40 × 4 × 1 h = **160 core-hours** |
| **Sum of task time** | 28.8 core-hours |
| **Time with no stage running** | 14 min |
| **GC time** | 3% of task time |
| **Peak heap per executor** | 4.3 GiB median, 5.3 GiB on the busiest |

*Illustrative figures: assumed, not measured.*

From those numbers: **18% of the core time ran tasks**, and the busiest executor used about **a third of its heap**. This post shows where each number comes from, and what to cut.

---

## The Two Numbers

| Number | Formula | What it tells you |
|--------|---------|-------------------|
| **Slot utilisation** | Σ task time ÷ Σ (executor uptime × executor cores) | How much of the core time you held actually ran tasks |
| **Peak heap headroom** | max peak heap used ÷ configured heap (`spark.executor.memory`) | How much of the heap you asked for was ever touched |

Everything you need is in three REST endpoints. They are served by the live UI on port 4040 while the app runs, and by the History Server on port 18080 after it finishes:

```bash
APP=http://localhost:18080/api/v1/applications/<app-id>   # add /<attempt-id> on YARN cluster mode

curl -s $APP                  # start/end time, completed flag
curl -s $APP/allexecutors     # active AND dead executors: cores, task time, peaks
curl -s $APP/environment      # spark.executor.memory and every other setting
```

Use `/allexecutors`, not `/executors`. The second one lists only active executors, so any executor removed during the run (by dynamic allocation or a failure) is missing from it.

---

## How Each Number Is Built

### 1. Slot utilisation: core time held vs core time used

An executor with 4 cores holds 4 **task slots** from the moment it is added until it is removed. Each slot either runs a task or sits idle. Slot utilisation is the share of slot-time that ran tasks.

<figure>
<svg viewBox="0 0 560 230" width="100%" style="max-width:560px" role="img" aria-label="Timeline of two executors with four slots each; filled blocks are tasks, empty space is idle slot time, including a gap where no stage runs">
  <g font-size="11" fill="currentColor">
    <text x="0" y="40">exec 1</text>
    <text x="0" y="126">exec 2</text>
  </g>
  <g fill="none" stroke="#c9c2b4">
    <rect x="60" y="20" width="480" height="76"/>
    <rect x="60" y="106" width="480" height="76"/>
    <path d="M60 39H540M60 58H540M60 77H540M60 125H540M60 144H540M60 163H540"/>
  </g>
  <g fill="#1f5f8b">
    <rect x="62" y="22" width="120" height="15"/><rect x="62" y="41" width="100" height="15"/><rect x="62" y="60" width="130" height="15"/><rect x="62" y="79" width="60" height="15"/>
    <rect x="62" y="108" width="110" height="15"/><rect x="62" y="127" width="125" height="15"/>
    <rect x="330" y="22" width="80" height="15"/><rect x="330" y="41" width="200" height="15"/>
    <rect x="330" y="108" width="70" height="15"/>
  </g>
  <rect x="200" y="20" width="120" height="162" fill="#b8381f" fill-opacity="0.12"/>
  <text x="260" y="104" text-anchor="middle" font-size="11" fill="#b8381f" font-weight="600">no stage running</text>
  <text x="260" y="118" text-anchor="middle" font-size="10" fill="#b8381f">(driver work)</text>
  <path d="M60 196H540" stroke="currentColor"/>
  <text x="60" y="212" font-size="10" fill="currentColor">addTime</text>
  <text x="540" y="212" font-size="10" fill="currentColor" text-anchor="end">removeTime / app end</text>
  <g font-size="11" fill="currentColor">
    <rect x="60" y="218" width="12" height="10" fill="#1f5f8b"/><text x="78" y="227">task running</text>
    <rect x="170" y="218" width="12" height="10" fill="none" stroke="#c9c2b4"/><text x="188" y="227">idle slot (you still pay)</text>
  </g>
</svg>
<figcaption>Each row is one task slot. Utilisation = blue area ÷ total box area.</figcaption>
</figure>

The fields, all on each `/allexecutors` entry:

| Field | Meaning (from the Spark docs) | Used for |
|-------|-------------------------------|----------|
| **`totalCores`** | Number of cores available in this executor | Slots per executor |
| **`addTime`**, **`removeTime`** | When the executor joined and left (no `removeTime` if it lived to the end) | Uptime |
| **`totalDuration`** | Elapsed time the JVM spent executing tasks, in ms | Busy slot-time |
| **`totalGCTime`** | Elapsed time spent in GC, summed, in ms | Sanity check on memory pressure |

`totalDuration` is the **sum** of task durations on that executor. Four tasks running at once for 10 seconds add 40 seconds, which is why you divide it by uptime × cores and not by uptime alone.

Skip the entry with `"id": "driver"`. It reports the driver, not a worker.

### 2. Where idle slot time comes from

A low utilisation number does not tell you *why* the slots were idle. There are three common shapes, and only the first two are fixed by sizing.

```
1. Too many slots for the work         2. Long tail                           3. Driver gaps
   (every stage)                          (end of a stage)                       (between stages)

slot 1 |██████░░░░░░░░░░|              slot 1 |████████░░░░░░░░|              slot 1 |████░░░░░░░░████|
slot 2 |████░░░░░░░░░░░░|              slot 2 |███████░░░░░░░░░|              slot 2 |███░░░░░░░░░████|
slot 3 |░░░░░░░░░░░░░░░░|              slot 3 |█████████░░░░░░░|              slot 3 |████░░░░░░░░███░|
slot 4 |░░░░░░░░░░░░░░░░|              slot 4 |████████████████|              slot 4 |██░░░░░░░░░░████|
        fewer tasks than slots                 one slow task holds the stage          collect, listing files,
                                                                                      planning, Python on driver
fix: fewer executors                   fix: Part 2 (skew, partitioning)       fix: code, not cluster size
```

The fastest way to tell them apart is the **Event Timeline** on the Jobs page. It shows executors being added and removed alongside each job and stage. Gaps between stage bars are shape 3. The script below also measures shape 3 directly: wall time minus the time covered by at least one stage.

### 3. Peak memory: what the executor actually touched

An executor's memory is several nested regions, and Spark reports a peak for most of them. Picking the right denominator is where most over-provisioning analysis goes wrong.

<figure>
<svg viewBox="0 0 560 250" width="100%" style="max-width:560px" role="img" aria-label="Executor container memory: heap (reserved 300 MiB, user memory, unified region split into storage and execution) plus overhead holding JVM off-heap and Python workers, with the peak metric that covers each region">
  <g font-size="11" fill="currentColor">
    <text x="0" y="16" font-weight="700">Container = spark.executor.memory + memoryOverhead (+ offHeap.size + pyspark.memory)</text>
  </g>
  <rect x="0" y="28" width="420" height="54" fill="none" stroke="#16252b" stroke-width="1.5"/>
  <rect x="0" y="28" width="22" height="54" fill="#c9c2b4"/>
  <rect x="22" y="28" width="158" height="54" fill="#c9c2b4" fill-opacity="0.45"/>
  <rect x="180" y="28" width="120" height="54" fill="#1f5f8b" fill-opacity="0.25"/>
  <rect x="300" y="28" width="120" height="54" fill="#1f5f8b" fill-opacity="0.5"/>
  <rect x="420" y="28" width="140" height="54" fill="#b8381f" fill-opacity="0.2" stroke="#b8381f"/>
  <g font-size="10.5" fill="currentColor" text-anchor="middle">
    <text x="11" y="60" transform="rotate(-90 11 58)">300 MiB</text>
    <text x="101" y="52">user memory</text><text x="101" y="66">(1 − memory.fraction)</text>
    <text x="240" y="52">storage</text><text x="240" y="66">(cache)</text>
    <text x="360" y="52">execution</text><text x="360" y="66">(shuffle, join, sort)</text>
    <text x="490" y="52">overhead</text><text x="490" y="66">JVM native, Python</text>
  </g>
  <path d="M180 92H420" stroke="#1f5f8b" stroke-width="2"/>
  <text x="300" y="106" text-anchor="middle" font-size="10.5" fill="#1f5f8b">unified region M ≈ maxMemory</text>
  <path d="M0 120H420" stroke="#16252b" stroke-width="2"/>
  <text x="210" y="134" text-anchor="middle" font-size="10.5" fill="currentColor">JVM heap = spark.executor.memory</text>
  <g font-size="10.5" fill="currentColor" font-family="JetBrains Mono, monospace">
    <text x="0" y="166">JVMHeapMemory ............. whole heap  ← divide by spark.executor.memory</text>
    <text x="0" y="184">OnHeapStorageMemory ....... storage part of M</text>
    <text x="0" y="202">OnHeapExecutionMemory ..... execution part of M</text>
    <text x="0" y="220">JVMOffHeapMemory .......... JVM non-heap (in overhead)</text>
    <text x="0" y="238">ProcessTreePythonRSSMemory  Python workers (needs processTreeMetrics)</text>
  </g>
</svg>
<figcaption>Region sizes are not to scale. M is a fraction (default 0.6) of heap minus 300 MiB.</figcaption>
</figure>

Unless you set `spark.executor.memoryOverhead` directly, overhead is executor memory × `spark.executor.memoryOverheadFactor`, with a minimum. The factor defaults to 0.10, or 0.40 for non-JVM jobs on Kubernetes.

| Peak metric (`peakMemoryMetrics.*`) | Covers | Compare against |
|-------------------------------------|--------|-----------------|
| **`JVMHeapMemory`** | Everything on the heap | `spark.executor.memory` |
| **`OnHeapExecutionMemory`** | Shuffle, join and sort buffers | `maxMemory` (the unified region) |
| **`OnHeapStorageMemory`** | Cached blocks | `maxMemory` |
| **`JVMOffHeapMemory`** | JVM non-heap memory | `memoryOverhead` |
| **`ProcessTreeJVMRSSMemory`** | Resident memory of the executor JVM process | The container size |
| **`ProcessTreePythonRSSMemory`** | Resident memory of PySpark workers | `memoryOverhead` or `spark.executor.pyspark.memory` |

The two `ProcessTree*` rows report 0 unless `spark.executor.processTreeMetrics.enabled=true` and the node has a `/proc` filesystem. Turn it on for PySpark jobs; without it, Python worker memory is invisible.

In the scenario, the unified region is about (16 GiB − 300 MiB) × 0.6 ≈ 9.4 GiB. A 5.3 GiB heap peak is 33% of the heap but 56% of `maxMemory`. Dividing by the wrong number makes the heap look much fuller than it is.

### 4. Where each number lives

| What | Spark UI | REST (`/api/v1/applications/<id>/…`) |
|------|----------|--------------------------------------|
| **Cores per executor** | Executors tab → **Cores** | `allexecutors[].totalCores` |
| **Executor lifetime** | Executors tab → **Add Time**, **Remove Time**; Jobs → **Event Timeline** | `addTime`, `removeTime` |
| **Task time and GC** | Executors tab → **Task Time (GC Time)** | `totalDuration`, `totalGCTime` |
| **Peak heap** | Executors tab → **Show Additional Metrics** → **Peak JVM Memory OnHeap / OffHeap** | `peakMemoryMetrics.JVMHeapMemory`, `.JVMOffHeapMemory` |
| **Peak execution memory** | Same menu → **Peak Execution Memory OnHeap / OffHeap**; per task on the stage page | `.OnHeapExecutionMemory` |
| **Peak cache memory** | Same menu → **Peak Storage Memory OnHeap / OffHeap** | `.OnHeapStorageMemory` |
| **Why an executor left** | Same menu → **Exec Loss Reason** | `removeReason` |
| **Configured memory and cores** | Environment tab → **Spark Properties** | `environment.sparkProperties` |
| **Stage start and end** | Stages tab | `stages[].submissionTime`, `.completionTime` |

The peak memory columns are hidden by default. Tick them under **Show Additional Metrics** at the top of the Executors tab.

The Executors tab already flags one problem for you: the Task Time (GC Time) cell is shaded red when GC time is over 10% of task time.

**What about `metrics.json`?** The driver also serves `/metrics/json` (the MetricsServlet sink, on by default). It holds the driver's own metric sources, such as the DAG scheduler, the block manager and the dynamic allocation targets. It is not the place to read per-executor busyness or peaks. Those come from the REST API above, or from the Prometheus-format endpoint `/metrics/executors/prometheus`, which the docs mark experimental.

---

## Measuring It

This script reads a finished or running app and prints both numbers, plus how much of the wall time had no stage running.

```python
#!/usr/bin/env python3
"""Usage: python3 overprov.py http://localhost:18080/api/v1/applications/<app-id>"""
import json, sys, urllib.request
from datetime import datetime, timezone
from statistics import median

BASE = sys.argv[1].rstrip("/")
UNITS = {"k": 2**10, "m": 2**20, "g": 2**30, "t": 2**40}


def get(path=""):
    with urllib.request.urlopen(BASE + path) as r:
        return json.load(r)


def ts(s):  # Spark REST dates look like 2026-10-28T09:00:00.000GMT
    return datetime.strptime(s.replace("GMT", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z")


def to_bytes(s):  # "16g", "512m"; a bare number means MiB
    s = s.strip().lower().removesuffix("b")
    return int(float(s[:-1]) * UNITS[s[-1]]) if s[-1] in UNITS else int(s) * 2**20


attempt = get()["attempts"][-1]
start = ts(attempt["startTime"])
end = ts(attempt["endTime"]) if attempt["completed"] else datetime.now(timezone.utc)

execs = [e for e in get("/allexecutors") if e["id"] != "driver"]
slot_ms = busy_ms = gc_ms = 0
for e in execs:
    gone = ts(e["removeTime"]) if e.get("removeTime") else end
    slot_ms += (gone - ts(e["addTime"])).total_seconds() * 1000 * e["totalCores"]
    busy_ms += e["totalDuration"]
    gc_ms += e["totalGCTime"]

# Wall time covered by at least one stage; the rest is driver-side work.
spans = sorted((ts(s["submissionTime"]), ts(s["completionTime"]))
               for s in get("/stages") if "submissionTime" in s and "completionTime" in s)
covered, cur_s, cur_e = 0.0, None, None
for s, e in spans:
    if cur_e is None or s > cur_e:
        if cur_e is not None:
            covered += (cur_e - cur_s).total_seconds()
        cur_s, cur_e = s, e
    else:
        cur_e = max(cur_e, e)
if cur_e is not None:
    covered += (cur_e - cur_s).total_seconds()
wall = (end - start).total_seconds()

props = dict(get("/environment")["sparkProperties"])
heap = to_bytes(props.get("spark.executor.memory", "1g"))
peaks = [e.get("peakMemoryMetrics", {}).get("JVMHeapMemory", 0) for e in execs]
py = max(e.get("peakMemoryMetrics", {}).get("ProcessTreePythonRSSMemory", 0) for e in execs)

print(f"executors (all time)      {len(execs)}")
print(f"slot utilisation          {busy_ms / slot_ms:.0%}")
print(f"idle core-hours           {(slot_ms - busy_ms) / 3.6e6:,.1f}")
print(f"wall time with no stage   {1 - covered / wall:.0%}")
print(f"GC / task time            {gc_ms / busy_ms:.0%}")
print(f"peak heap / heap  max     {max(peaks) / heap:.0%}")
print(f"peak heap / heap  median  {median(peaks) / heap:.0%}")
print(f"peak Python RSS           {py / 2**30:.1f} GiB" if py else
      "peak Python RSS           n/a (processTreeMetrics off, or not PySpark)")
```

For the scenario it would print something like:

```
executors (all time)      40
slot utilisation          18%
idle core-hours           131.2
wall time with no stage   23%
GC / task time            3%
peak heap / heap  max     33%
peak heap / heap  median  27%
peak Python RSS           n/a (processTreeMetrics off, or not PySpark)
```

*Illustrative output: computed from the assumed scenario, not from a real run.*

It needs a real cluster. In `local` mode the driver is the only executor, so the list is empty after the driver is filtered out.

---

## How the Pieces Fit

<pre class="mermaid">
flowchart LR
    A["/allexecutors<br/>cores, uptime,<br/>task time, peaks"] --> U["Slot utilisation"]
    A --> M["Peak heap headroom"]
    E["/environment<br/>spark.executor.memory"] --> M
    S["/stages<br/>submission, completion"] --> G["Wall time with<br/>no stage running"]
    U --> V{"Verdict"}
    M --> V
    G --> V
    V --> C1["Cut executors"]
    V --> C2["Cut memory per executor"]
    V --> C3["Fix driver code"]
    V --> C4["Sized right:<br/>see Part 2 if slow"]
</pre>

---

## Reading the Result

The thresholds below are starting points that I use, not Spark rules. Tune them on your own jobs.

| Slot utilisation | Peak heap / heap | Verdict | What to change |
|------------------|------------------|---------|----------------|
| **Low** (under ~40%) | **Low** (under ~50%) | Too many executors, too much memory each | Cut executor count first, then memory |
| **Low** | **High** (over ~80%) | Memory-bound, cores idle | Fewer cores per executor at the same memory, or a memory-heavier instance type |
| **High** | **Low** | Cores busy, heap mostly empty | Less memory per executor, or more cores at the same memory |
| **High** | **High** | About right | If it is still slow, the cause is in Part 2 |
| **Low, with a large no-stage share** | any | Driver-bound | Fix the driver-side code; resizing won't help |

The scenario lands in the first row, with a sizeable driver gap. Cutting executors is safe. The 14 minutes of driver time won't shrink either way, so expect the wall time to stay close to an hour.

---

## Where It Hurts

| Watch-out | Why it matters | What to do |
|-----------|----------------|------------|
| **Dividing heap peak by `maxMemory`** | `maxMemory` is the storage/execution region, not the heap | Divide `JVMHeapMemory` by `spark.executor.memory` |
| **Peaks are sampled** | Executor metrics are updated on each heartbeat (`spark.executor.heartbeatInterval`, default 10s), so short spikes can be missed | Set `spark.executor.metrics.pollingInterval` (ms) for faster polling, and keep a safety margin |
| **Python memory not reported** | `ProcessTree*` metrics are 0 unless enabled | `spark.executor.processTreeMetrics.enabled=true` on PySpark jobs |
| **Using app duration as executor uptime** | With dynamic allocation, executors come and go | Use each executor's `addTime` and `removeTime`, as the script does |
| **Using `/executors`** | It lists only active executors, so removed ones vanish | Use `/allexecutors` |
| **Old stages missing** | The UI and REST API keep up to `spark.ui.retainedStages` stages (default 1000) | Read finished apps from the History Server; raise the limit for long apps |
| **Cached data pins executors** | With dynamic allocation, executors holding cached data are never removed by default | Check `spark.dynamicAllocation.cachedExecutorIdleTimeout`, and unpersist when done |
| **Skew looks like over-provisioning** | One long task leaves the other slots idle (shape 2) | Check the stage's max vs median task time before cutting (Part 2) |

---

## When Not to Cut

| Situation | Why low utilisation can be fine |
|-----------|---------------------------------|
| **Latency-bound streaming** | Spare slots absorb bursts; the goal is batch latency, not busy cores |
| **Spot or pre-emptible nodes** | Spare capacity covers lost executors without missing the deadline |
| **Shared cluster you don't pay for per app** | Idle slots go to other apps; the waste is smaller than it looks |
| **Wall time is a hard SLA** | Cut in steps and stop when wall time moves, not when utilisation looks good |

---

## Right-Sizing Safely

<pre class="mermaid">
flowchart TD
    A["Measure baseline:<br/>wall time, utilisation,<br/>peak heap, spill, GC"] --> B{"No-stage share large?"}
    B -- yes --> B1["Fix driver code first"]
    B -- no --> C{"Utilisation low?"}
    C -- yes --> D["Cut executors by a step"]
    C -- no --> E{"Peak heap low?"}
    D --> R["Rerun on the same input"]
    E -- yes --> F["Cut memory per executor by a step"]
    E -- no --> Z["Done: sized about right"]
    F --> R
    R --> Q{"Wall time, spill<br/>and GC still OK?"}
    Q -- yes --> C
    Q -- no --> P["Go back one step and stop"]
</pre>

Change one dimension at a time. If you change executor count and memory together and the job slows down, you won't know which change caused it.

---

## Checking It Works

1. **Run the script on the baseline** and save the output with the input size for that run.
2. **Cut one step** (for example, half the executors) and rerun on the same input, or on an input of the same size.
3. **Compare four things:** wall time, slot utilisation, peak heap headroom, and disk spill on the Stages tab. Utilisation should rise. Wall time and spill should stay flat.
4. **Check the Executors tab** for red GC cells and for **Exec Loss Reason** entries. Either one means you cut too far.

---

## Sources

Checked on 2026-10-28.

| Source | Used for |
|--------|----------|
| [Spark Monitoring and Instrumentation (4.2.0)](https://spark.apache.org/docs/latest/monitoring.html) | REST endpoints and ports, `/executors` vs `/allexecutors`, executor field meanings, `peakMemoryMetrics`, heartbeat updates, process tree conditions, MetricsServlet, Prometheus endpoint, `logStageExecutorMetrics` |
| [Spark Configuration](https://spark.apache.org/docs/latest/configuration.html) | `memoryOverhead` and container size, `metrics.pollingInterval`, `processTreeMetrics.enabled`, `heartbeatInterval`, `ui.retainedStages` |
| [Spark Tuning Guide](https://spark.apache.org/docs/latest/tuning.html) | Unified region M, `spark.memory.fraction` default 0.6, the 300 MiB reserve |
| [Spark Job Scheduling](https://spark.apache.org/docs/latest/job-scheduling.html) | Dynamic allocation idle removal and cached executors |
| [Spark Web UI](https://spark.apache.org/docs/latest/web-ui.html) | Event Timeline, stage task metrics |
| [Executors page template](https://github.com/apache/spark/blob/v3.5.3/core/src/main/resources/org/apache/spark/ui/static/executorspage-template.html) and [script](https://github.com/apache/spark/blob/v3.5.3/core/src/main/resources/org/apache/spark/ui/static/executorspage.js) (v3.5.3) | Executors tab column names, Show Additional Metrics options, the 10% GC shading |
| [`api.scala`](https://github.com/apache/spark/blob/v3.5.3/core/src/main/scala/org/apache/spark/status/api/v1/api.scala) and [`AppStatusListener.scala`](https://github.com/apache/spark/blob/v3.5.3/core/src/main/scala/org/apache/spark/status/AppStatusListener.scala) (v3.5.3) | `ExecutorSummary` fields; `totalDuration` is the sum of task durations |
