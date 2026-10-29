---
layout: post
title: "Parquet Under the Hood: How a Query Reads Less"
date: 2026-10-29
categories: [parquet, spark, data-engineering]
---

# Parquet Under the Hood: How a Query Reads Less

<a href="/assets/images/2026-10-29-parquet-under-the-hood-hero.png"><img src="/assets/images/2026-10-29-parquet-under-the-hood-hero.png" alt="Parquet cheat sheet: file layout from PAR1 magic through row groups, column chunks, pages and footer; column pruning, encoding and compression, and the data skipping ladder of partition pruning, row group min/max, dictionary filter, bloom filter and page index; how to read PushedFilters, PartitionFilters and post-scan Filter in a Spark plan; what Delta and Iceberg add on top; and the parquet-cli commands to inspect a file" style="width:100%;height:auto;border-radius:8px"></a>
<p style="text-align:center;font-size:0.85em;margin-top:0.3em"><em>Click to open full size.</em></p>

Parquet stores a table column by column and writes statistics about every block it writes. A reader uses those statistics to skip whole blocks without decoding them, then reads only the columns the query asks for. Delta Lake and Apache Iceberg both store their data as Parquet files, so everything in this post is also how they read data. They add a layer on top, covered at the end.

This is a prerequisite post for the bootcamp series. Later posts on Delta, Iceberg and liquid clustering build on the terms defined here: **row group**, **column chunk**, **page**, **footer**, **min/max statistics** and **predicate pushdown**.

---

## The Scenario

One query, run against the same data stored in different ways.

```sql
SELECT user_id, country, amount
FROM   events
WHERE  event_date = DATE '2026-10-01'
AND    country    = 'IE'
```

| Assumption | Value |
|------------|-------|
| **Table** | `events`: 2 million rows over one year (2026), 19 columns |
| **Columns read** | 3 of 19, plus the filter columns |
| **Matching rows** | 280 (one day of 365, one country of 20) |
| **Engine** | Spark 4.2.1 (writes with parquet-java 1.17.0), local mode, Scala `spark-shell` |
| **Layouts compared** | CSV; Parquet unsorted; Parquet sorted by `event_date, country`; Parquet partitioned by `event_date` |
| **Row group size** | Lowered to 4 MB (`parquet.block.size`) so one file has 53 row groups to skip between |

The table is small enough to run on a laptop. Every number and plan in this post comes from running [the script at the end](#reproduce-it) on that data.

| Layout | Size on disk | Rows Spark decoded | Rows returned | What did the work |
|--------|-------------:|-------------------:|--------------:|-------------------|
| **CSV** | 319 MiB | every line (all 319.5 MiB read) | 280 | Nothing: no columns or blocks to skip |
| **Parquet, unsorted** | 107 MiB | 2,000,000 | 280 | Column pruning only. Every row group spans the whole year |
| **Parquet, sorted, pushdown off** | 156 MiB | 2,000,000 | 280 | Column pruning only (`spark.sql.parquet.filterPushdown=false`) |
| **Parquet, sorted** | 156 MiB | **38,440** | 280 | Min/max kept 2 of 53 row groups; the page index kept 1 page in each |
| **Parquet, partitioned by date** | 151 MiB in 365 files | **5,522** | 280 | Partition pruning opened 1 file of 365 |

*Measured on a laptop with Spark's task input metrics (`recordsRead`). Spark's input byte counter gave inconsistent numbers for the Parquet runs on a local disk (pushdown off reported fewer bytes than pushdown on), so bytes are only shown for CSV. The sorted file is larger than the unsorted one because it also carries 53 MB of bloom filters; section 3d explains why.*

The same 3 columns and the same rows come back each time. What changes is how much of the file the reader has to touch to find them.

---

## What You Get

| Benefit | What it means in practice | Mechanism |
|---------|---------------------------|-----------|
| **Column pruning** | A query that reads 3 of 19 columns skips the other 16 column chunks entirely | Values stored by column, located by byte offset in the footer |
| **Smaller files** | Repeated and similar values shrink before the codec even runs | Dictionary, run-length and delta encodings, then snappy or zstd |
| **Data skipping** | Blocks whose statistics can't match the filter are never read | Min/max, null counts, dictionaries, bloom filters, page index |
| **Self-describing** | Any engine can read the file with no external schema | Schema and types stored in the footer |
| **Parallel reads** | One large file is read by many tasks at once | Row groups are independent units with known offsets |
| **Fast vectorized decoding** | Values of one type sit together, so the reader decodes them in batches | Columnar pages, Spark's vectorized reader (on by default) |

Writing and reading Parquet from Spark (Scala):

```scala
// Write: sort first so related rows share row groups (makes min/max useful)
events
  .sortWithinPartitions("event_date", "country")
  .write
  .option("compression", "zstd")                         // default is snappy
  .option("parquet.bloom.filter.enabled#user_id", "true") // off by default
  .parquet("s3://lake/events")

// Read: select only the columns you need, filter on raw columns
spark.read.parquet("s3://lake/events")
  .where($"event_date" === "2026-10-01" && $"country" === "IE")
  .select("user_id", "country", "amount")
```

---

## Inside a Parquet File

A Parquet file is a sequence of **row groups**, followed by a **footer**. Inside each row group, every column has one **column chunk**, and each column chunk is split into **pages**.

<figure>
<svg viewBox="0 0 560 330" width="100%" style="max-width:560px" role="img" aria-label="Parquet file layout: PAR1 magic, row group 1 and row group 2, each with column chunks for event_date, country and amount made of pages, then the footer with schema, row group metadata and column statistics, then the 4-byte footer length and PAR1 magic">
  <g font-size="11" fill="currentColor">
    <rect x="0" y="0" width="560" height="22" fill="#c9c2b4" fill-opacity="0.5"/>
    <text x="8" y="15" font-family="JetBrains Mono, monospace">PAR1</text>
    <text x="70" y="15">4-byte magic number</text>
  </g>
  <g>
    <rect x="0" y="28" width="560" height="98" fill="none" stroke="#1f5f8b" stroke-width="1.5"/>
    <text x="8" y="44" font-size="11" font-weight="700" fill="#1f5f8b">Row group 1 (rows 0 – 999,999)</text>
    <g font-size="10" fill="currentColor">
      <text x="8" y="66">event_date</text><text x="8" y="90">country</text><text x="8" y="114">amount</text>
    </g>
    <g fill="#1f5f8b" fill-opacity="0.25" stroke="#1f5f8b">
      <rect x="80" y="54" width="18" height="16" fill="#b8381f" fill-opacity="0.3" stroke="#b8381f"/>
      <rect x="100" y="54" width="70" height="16"/><rect x="172" y="54" width="70" height="16"/><rect x="244" y="54" width="70" height="16"/>
      <rect x="80" y="78" width="18" height="16" fill="#b8381f" fill-opacity="0.3" stroke="#b8381f"/>
      <rect x="100" y="78" width="60" height="16"/><rect x="162" y="78" width="60" height="16"/>
      <rect x="80" y="102" width="90" height="16"/><rect x="172" y="102" width="90" height="16"/><rect x="264" y="102" width="90" height="16"/><rect x="356" y="102" width="90" height="16"/>
    </g>
    <text x="370" y="66" font-size="10" fill="currentColor">← column chunk = pages</text>
    <text x="370" y="90" font-size="10" fill="#b8381f">■ dictionary page</text>
  </g>
  <g>
    <rect x="0" y="132" width="560" height="34" fill="none" stroke="#1f5f8b" stroke-width="1.5" stroke-dasharray="5 3"/>
    <text x="8" y="153" font-size="11" font-weight="700" fill="#1f5f8b">Row group 2 … row group N (same structure)</text>
  </g>
  <g>
    <rect x="0" y="172" width="560" height="22" fill="#c9c2b4" fill-opacity="0.25" stroke="#c9c2b4"/>
    <text x="8" y="187" font-size="10.5" fill="currentColor">Column index + offset index (page-level min/max and page offsets) · bloom filters</text>
  </g>
  <g>
    <rect x="0" y="200" width="560" height="78" fill="#b8381f" fill-opacity="0.08" stroke="#b8381f" stroke-width="1.5"/>
    <text x="8" y="217" font-size="11" font-weight="700" fill="#b8381f">Footer (FileMetaData)</text>
    <g font-size="10.5" fill="currentColor">
      <text x="8" y="235">schema: names, physical and logical types, nesting</text>
      <text x="8" y="251">per row group: row count, and per column chunk: byte offset, size, encodings, codec</text>
      <text x="8" y="267">per column chunk statistics: min, max, null_count · offsets of page index and bloom filter</text>
    </g>
  </g>
  <g font-size="11" fill="currentColor">
    <rect x="0" y="284" width="560" height="22" fill="#c9c2b4" fill-opacity="0.5"/>
    <text x="8" y="299" font-family="JetBrains Mono, monospace">4 bytes</text><text x="70" y="299">footer length (little endian)</text>
    <rect x="0" y="308" width="560" height="22" fill="#c9c2b4" fill-opacity="0.5"/>
    <text x="8" y="323" font-family="JetBrains Mono, monospace">PAR1</text><text x="70" y="323">4-byte magic number</text>
  </g>
</svg>
<figcaption>Data first, metadata last. The page index and bloom filters sit outside the row groups so readers that don't use them never pay for them.</figcaption>
</figure>

| Term | What it is | Typical size |
|------|------------|--------------|
| **Row group** | A horizontal slice of the table: a range of rows, all columns | parquet-java writes 128 MB by default (`parquet.block.size`); the format docs recommend 512 MB to 1 GB |
| **Column chunk** | One column's values for one row group, stored contiguously | One per column per row group |
| **Page** | The unit of encoding and compression inside a column chunk | 1 MB or 20,000 rows by default in parquet-java, whichever comes first |
| **Dictionary page** | The distinct values of the column chunk, if dictionary encoding is used | One per column chunk, before the data pages |
| **Data page** | Repetition levels, definition levels, then the encoded values | Many per column chunk |
| **Footer** | Schema, row group list, byte offsets, statistics | Usually KBs |

The footer is written last so the writer can stream the data in one pass and only describe it at the end. A reader works the other way round:

<pre class="mermaid">
sequenceDiagram
    participant R as Reader
    participant F as Parquet file
    R->>F: Read last 8 bytes
    F-->>R: footer length + PAR1
    R->>F: Read footer
    F-->>R: schema, row groups, offsets, min/max
    Note over R: Decide which row groups<br/>and which columns are needed
    R->>F: Read page index / dictionary / bloom filter<br/>(only for filter columns)
    Note over R: Decide which pages are needed
    R->>F: Ranged reads of the surviving column chunks and pages
    F-->>R: Encoded, compressed pages
    Note over R: Decompress, decode, re-check the filter on each row
</pre>

On object storage, each of those reads is a ranged GET. The reader never downloads the whole file just to find out what is in it.

---

## How It Works Underneath

### 1. Column pruning: only read the columns you select

A row format such as CSV or Avro stores each row's values together. To get 3 columns, the reader still has to read and parse all 20. Parquet stores each column's values together, and the footer records the byte offset and length of every column chunk. The reader seeks straight to the 3 chunks it needs.

<figure>
<svg viewBox="0 0 560 190" width="100%" style="max-width:560px" role="img" aria-label="Row layout reads every field of every row; columnar layout reads only the three selected column chunks">
  <text x="0" y="14" font-size="12" font-weight="700" fill="currentColor">Row layout (CSV, Avro)</text>
  <g font-size="9.5" fill="currentColor">
    <text x="0" y="36">row 1</text><text x="0" y="56">row 2</text><text x="0" y="76">row 3</text>
  </g>
  <g fill="#b8381f" fill-opacity="0.35" stroke="#b8381f" stroke-width="0.6">
    <rect x="34" y="26" width="200" height="14"/><rect x="34" y="46" width="200" height="14"/><rect x="34" y="66" width="200" height="14"/>
  </g>
  <text x="34" y="100" font-size="10" fill="#b8381f">every byte of every row is read and parsed</text>
  <text x="300" y="14" font-size="12" font-weight="700" fill="currentColor">Columnar layout (Parquet)</text>
  <g font-size="9" fill="currentColor" text-anchor="middle">
    <text x="312" y="36">id</text><text x="340" y="36">ts</text><text x="368" y="36">date</text><text x="396" y="36">user</text><text x="424" y="36">ctry</text><text x="452" y="36">dev</text><text x="480" y="36">amt</text><text x="508" y="36">attr…</text>
  </g>
  <g stroke="#c9c2b4" fill="none">
    <rect x="300" y="42" width="24" height="56"/><rect x="328" y="42" width="24" height="56"/><rect x="356" y="42" width="24" height="56"/><rect x="440" y="42" width="24" height="56"/><rect x="496" y="42" width="24" height="56"/>
  </g>
  <g fill="#1f5f8b" fill-opacity="0.55">
    <rect x="384" y="42" width="24" height="56"/><rect x="412" y="42" width="24" height="56"/><rect x="468" y="42" width="24" height="56"/>
  </g>
  <text x="300" y="116" font-size="10" fill="#1f5f8b">only user_id, country, amount chunks are read</text>
  <g font-size="10.5" fill="currentColor" font-family="JetBrains Mono, monospace">
    <text x="0" y="150">ReadSchema: struct&lt;user_id:string,country:string,amount:double&gt;</text>
    <text x="0" y="170">           ↑ shown in Spark's FileScan node: the columns actually read</text>
  </g>
</svg>
<figcaption>Filter columns are read too (event_date here), but only to evaluate the filter.</figcaption>
</figure>

Two things quietly defeat pruning:

| Pattern | What happens | Fix |
|---------|--------------|-----|
| **`SELECT *` or `df.collect()` on the whole frame** | Every column chunk is read | Select columns before the action |
| **A UDF or `map` over the whole row** | Spark must hand the UDF every field | Select the columns the UDF needs, then apply it |

### 2. Encoding and compression: make each column small

Parquet shrinks a column twice. First an **encoding** turns the values into a compact representation that depends on the data. Then a general-purpose **codec** (snappy by default in Spark) compresses each page.

Take 12 values of the `country` column after sorting:

```
Raw values (PLAIN)       IE IE IE IE IE IE IE GB GB GB US US        12 strings

Step 1: dictionary       dictionary page:  0 → IE   1 → GB   2 → US
                         data page ids:    0 0 0 0 0 0 0 1 1 1 2 2   12 small integers

Step 2: RLE / bit-pack   run(0, ×7)  run(1, ×3)  run(2, ×2)           3 runs
        (the ids)        ids need only 2 bits each when they don't repeat

Step 3: codec            snappy / zstd over the encoded page bytes
```

Sorted data turns into long runs, and long runs collapse to almost nothing. Unsorted, the same column becomes a stream of 5-bit ids (20 countries) with no runs, which is still far smaller than repeating the strings.

Here is what that looks like on the scenario data. These are real column sizes from `parquet column-size`, same 2 million rows, same codec:

| Column | Unsorted | Sorted by `event_date, country` | Why |
|--------|---------:|--------------------------------:|-----|
| **`event_date`** | 2.23 MiB | **7.8 KiB** | 365 values; sorted, each page is one or two long runs |
| **`country`** | 1.21 MiB | **31.8 KiB** | Sorted within each day, so 20 long runs per day |
| **`device`** | 30.5 KiB | 499 KiB | The unsorted file kept the generator's order, where `device` cycles ios, android, web. Sorting by date broke that pattern |
| **`user_id`** | 11.7 MiB | 11.7 MiB | 500,000 distinct values: written without a dictionary (PLAIN), so sort order doesn't matter |

Sorting helps the columns you sort by and can hurt the others. Pick the sort columns from your filters, not from compression alone.

| Encoding | Used for | How it shrinks data |
|----------|----------|---------------------|
| **PLAIN** | Anything; the fallback | Values back to back, no tricks |
| **RLE_DICTIONARY** | Low and medium cardinality columns | Store each distinct value once; data pages hold small integer ids |
| **RLE / bit-packing hybrid** | Dictionary ids, booleans, repetition and definition levels | Runs of the same value become (value, count); others use the minimum bit width |
| **DELTA_BINARY_PACKED** | INT32, INT64 (ids, timestamps) | Stores differences between neighbours, bit-packed |
| **DELTA_BYTE_ARRAY** | Strings with shared prefixes (URLs, keys) | Stores the shared-prefix length plus the suffix |
| **BYTE_STREAM_SPLIT** | Floats and doubles | Regroups bytes by position so the codec compresses them better; doesn't shrink on its own |

**Dictionary fallback.** If a column chunk's dictionary grows past `parquet.dictionary.page.size` (1 MB by default in parquet-java), the writer stops adding to it and writes the rest of the chunk with PLAIN encoding. That matters for skipping too: section 3d only works when the whole chunk is dictionary encoded.

**Timestamps in Spark default to INT96.** Spark writes `TimestampType` as the legacy INT96 physical type (`spark.sql.parquet.outputTimestampType` is `INT96` in 4.2.1). In the scenario file, `parquet meta` shows no min/max for `event_ts` at all, so a filter on it can't skip anything. Set the option to `TIMESTAMP_MICROS` for new tables.

**Codec choice in Spark** is set with `spark.sql.parquet.compression.codec` (default `snappy`) or the `compression` write option. Accepted values include `snappy`, `gzip`, `lz4_raw`, `zstd` and `none`. Iceberg's default for Parquet is `zstd`.

### 3. Data skipping: the main event

Column pruning decides **which columns** to read. Data skipping decides **which rows' blocks** to read. It works in levels, from coarsest to finest. Each level uses metadata that is much smaller than the data it lets the reader skip.

| Level | Unit skipped | Metadata used | Helps with | Where it lives |
|-------|--------------|---------------|------------|----------------|
| **a. Partition pruning** | Whole directories of files | Directory names (`event_date=2026-10-01/`) | Filters on the partition column | Not Parquet: the table layout |
| **b. Row group min/max** | Row groups | `min`, `max`, `null_count` per column chunk | Ranges and equality on sorted or clustered columns | Footer |
| **c. Dictionary filter** | Row groups | The column chunk's dictionary page | Equality and `IN` on low-cardinality columns | Dictionary page |
| **d. Bloom filter** | Row groups | Bit set of hashed values | Equality on high-cardinality columns (ids) | Bloom filter block, offset in footer |
| **e. Page index** | Pages inside a row group | Per-page min/max and row offsets | Selective filters on sorted columns | Column index and offset index, near the footer |
| **f. Row filter** | Individual rows | The decoded values | Everything; always runs | Spark, after the scan |

None of a to e is exact. Each one answers **"definitely not here"** or **"maybe here"**. Whatever survives is decoded, and Spark checks the filter again on every row.

The slides below walk through each level for the scenario query.

<div class="slides">

<figure>
<svg viewBox="0 0 560 270" width="100%" style="max-width:560px" role="img" aria-label="Slide 1: the footer of the sorted file lists 53 row groups with min and max for each column, read before any data page">
  <rect x="0" y="0" width="560" height="26" fill="#16252b"/>
  <text x="10" y="18" font-size="12" font-weight="700" fill="#f6f3ec">Slide 1 / 7 · Read the footer first</text>
  <text x="550" y="18" font-size="11" fill="#f6f3ec" text-anchor="end">WHERE event_date = 2026-10-01 AND country = 'IE'</text>
  <g font-size="10.5" fill="currentColor" font-family="JetBrains Mono, monospace">
    <g font-weight="700"><text x="10" y="50">row group</text><text x="90" y="50">rows</text><text x="160" y="50">event_date min … max</text><text x="350" y="50">country</text><text x="430" y="50">user_id</text></g>
    <text x="10" y="72">RG 0</text><text x="90" y="72">38,440</text><text x="160" y="72">2026-01-01 … 2026-01-08</text><text x="350" y="72">AT … US</text><text x="430" y="72">u-100002 … u-9997</text>
    <text x="10" y="90">RG 1</text><text x="90" y="90">38,440</text><text x="160" y="90">2026-01-08 … 2026-01-15</text><text x="350" y="90">AT … US</text><text x="430" y="90">u-10 … u-99999</text>
    <text x="10" y="108">…</text>
    <text x="10" y="126">RG 38</text><text x="90" y="126">38,440</text><text x="160" y="126">2026-09-24 … 2026-10-01</text><text x="350" y="126">AT … US</text><text x="430" y="126">u-1 … u-9999</text>
    <text x="10" y="144">RG 39</text><text x="90" y="144">38,440</text><text x="160" y="144">2026-10-01 … 2026-10-08</text><text x="350" y="144">AT … US</text><text x="430" y="144">…</text>
    <text x="10" y="162">…</text>
    <text x="10" y="180">RG 52</text><text x="90" y="180">1,120</text><text x="160" y="180">2026-12-31 …</text>
  </g>
  <rect x="0" y="192" width="560" height="78" fill="#1f5f8b" fill-opacity="0.08"/>
  <g font-size="11.5" fill="currentColor">
    <text x="10" y="212">One small read of the file's tail gives the reader all 53 row groups, where each</text>
    <text x="10" y="230">column chunk starts, and the min and max of every column.</text>
    <text x="10" y="254" font-weight="700" fill="#1f5f8b">No data page has been read yet.</text>
  </g>
</svg>
<figcaption>Real values from <code>parquet meta</code> on the sorted scenario file. Strings compare byte by byte, which is why u-9997 sorts after u-100002.</figcaption>
</figure>

<figure>
<svg viewBox="0 0 560 250" width="100%" style="max-width:560px" role="img" aria-label="Slide 2: partition pruning lists only the matching directory before any Parquet file is opened">
  <rect x="0" y="0" width="560" height="26" fill="#16252b"/>
  <text x="10" y="18" font-size="12" font-weight="700" fill="#f6f3ec">Slide 2 / 7 · a. Partition pruning (before Parquet)</text>
  <g font-size="11" font-family="JetBrains Mono, monospace" fill="currentColor">
    <text x="10" y="52">events/</text>
    <text x="30" y="74" opacity="0.4">event_date=2026-09-29/  part-0.parquet</text>
    <text x="30" y="94" opacity="0.4">event_date=2026-09-30/  part-0.parquet</text>
    <text x="30" y="114" font-weight="700" fill="#1f5f8b">event_date=2026-10-01/  part-0.parquet   ← listed and opened</text>
    <text x="30" y="134" opacity="0.4">event_date=2026-10-02/  part-0.parquet</text>
    <text x="30" y="154" opacity="0.4">… 361 more directories, never opened</text>
  </g>
  <rect x="0" y="170" width="560" height="80" fill="#1f5f8b" fill-opacity="0.08"/>
  <g font-size="11.5" fill="currentColor">
    <text x="10" y="192">Spark matches the filter against directory names, so 364 of 365 files are</text>
    <text x="10" y="210">never opened. This is a table-layout feature, not a Parquet one: the value</text>
    <text x="10" y="228">lives in the path, and the column isn't stored in the files at all.</text>
    <text x="10" y="246" fill="#b8381f">Shows in the plan as PartitionFilters.</text>
  </g>
</svg>
</figure>

<figure>
<svg viewBox="0 0 560 270" width="100%" style="max-width:560px" role="img" aria-label="Slide 3: in an unsorted file, every row group's event_date range covers the whole year, so the predicate line crosses all of them and nothing is skipped">
  <rect x="0" y="0" width="560" height="26" fill="#16252b"/>
  <text x="10" y="18" font-size="12" font-weight="700" fill="#f6f3ec">Slide 3 / 7 · b. Row group min/max: unsorted file</text>
  <g font-size="10" fill="currentColor"><text x="80" y="46">Jan</text><text x="520" y="46" text-anchor="end">Dec</text><text x="10" y="46">event_date</text></g>
  <path d="M80 52H520" stroke="#c9c2b4"/>
  <g font-size="10" fill="currentColor">
    <text x="10" y="72">RG 0</text><text x="10" y="94">RG 1</text><text x="10" y="116">RG 2</text><text x="10" y="138">RG 3</text><text x="10" y="160">…</text>
  </g>
  <g fill="#b8381f" fill-opacity="0.3" stroke="#b8381f">
    <rect x="80" y="62" width="440" height="14"/><rect x="81" y="84" width="438" height="14"/><rect x="80" y="106" width="439" height="14"/><rect x="82" y="128" width="438" height="14"/>
  </g>
  <path d="M410 54V170" stroke="#16252b" stroke-width="2" stroke-dasharray="4 3"/>
  <text x="410" y="182" font-size="10" fill="currentColor" text-anchor="middle">2026-10-01</text>
  <rect x="0" y="194" width="560" height="76" fill="#b8381f" fill-opacity="0.08"/>
  <g font-size="11.5" fill="currentColor">
    <text x="10" y="214">Rows arrived in random date order, so every row group holds some rows from</text>
    <text x="10" y="232">every day. All 53 ranges are 2026-01-01 … 2026-12-31 and contain 2026-10-01.</text>
    <text x="10" y="254" font-weight="700" fill="#b8381f">Every row group is "maybe". Nothing is skipped.</text>
  </g>
</svg>
</figure>

<figure>
<svg viewBox="0 0 560 270" width="100%" style="max-width:560px" role="img" aria-label="Slide 4: in the sorted file each row group covers about a week; 2026-10-01 sits on the boundary, so row groups 38 and 39 survive and the other 51 are skipped">
  <rect x="0" y="0" width="560" height="26" fill="#16252b"/>
  <text x="10" y="18" font-size="12" font-weight="700" fill="#f6f3ec">Slide 4 / 7 · b. Row group min/max: sorted file</text>
  <g font-size="10" fill="currentColor"><text x="80" y="46">Jan</text><text x="520" y="46" text-anchor="end">Dec</text><text x="10" y="46">event_date</text></g>
  <path d="M80 52H520" stroke="#c9c2b4"/>
  <g font-size="10" fill="currentColor">
    <text x="10" y="72">RG 0</text><text x="10" y="94">RG 1</text><text x="10" y="116">…</text><text x="10" y="138">RG 38</text><text x="10" y="160">RG 39</text>
  </g>
  <g fill="#c9c2b4" fill-opacity="0.5" stroke="#c9c2b4">
    <rect x="80" y="62" width="9" height="14"/><rect x="89" y="84" width="9" height="14"/>
  </g>
  <g fill="#1f5f8b" fill-opacity="0.6" stroke="#1f5f8b">
    <rect x="401" y="128" width="9" height="14"/><rect x="410" y="150" width="9" height="14"/>
  </g>
  <text x="120" y="118" font-size="10" fill="currentColor">… each row group covers about one week (38,440 rows) …</text>
  <path d="M410 54V170" stroke="#16252b" stroke-width="2" stroke-dasharray="4 3"/>
  <text x="410" y="182" font-size="10" fill="currentColor" text-anchor="middle">2026-10-01</text>
  <text x="428" y="142" font-size="10" fill="#1f5f8b">09-24 … 10-01</text>
  <text x="428" y="164" font-size="10" fill="#1f5f8b">10-01 … 10-08</text>
  <rect x="0" y="194" width="560" height="76" fill="#1f5f8b" fill-opacity="0.08"/>
  <g font-size="11.5" fill="currentColor">
    <text x="10" y="214">The same rows, sorted before writing. For each row group: is max &lt; 2026-10-01</text>
    <text x="10" y="232">or min &gt; 2026-10-01? Then skip it. The day falls on a boundary, so two match.</text>
    <text x="10" y="254" font-weight="700" fill="#1f5f8b">2 of 53 row groups survive. The other 51 are never read.</text>
  </g>
</svg>
<figcaption>Min/max statistics are only as good as the data's sort order. This is why Z-ordering and liquid clustering exist.</figcaption>
</figure>

<figure>
<svg viewBox="0 0 560 260" width="100%" style="max-width:560px" role="img" aria-label="Slide 5: the country range AT to US contains IE, so min/max says maybe, but the dictionary page lists only five countries without IE, so the row group is skipped">
  <rect x="0" y="0" width="560" height="26" fill="#16252b"/>
  <text x="10" y="18" font-size="12" font-weight="700" fill="#f6f3ec">Slide 5 / 7 · c. Dictionary filter</text>
  <g font-size="11" fill="currentColor">
    <text x="10" y="52" font-weight="700">Row group 7 · country</text>
    <text x="10" y="74">min/max:</text>
    <text x="80" y="74" font-family="JetBrains Mono, monospace">AT … US</text>
    <text x="180" y="74" fill="#b8381f">IE is between AT and US → "maybe"</text>
    <text x="10" y="102">dictionary:</text>
  </g>
  <g font-size="11" font-family="JetBrains Mono, monospace" fill="currentColor">
    <rect x="80" y="88" width="44" height="22" fill="none" stroke="#1f5f8b"/><text x="102" y="103" text-anchor="middle">AT</text>
    <rect x="128" y="88" width="44" height="22" fill="none" stroke="#1f5f8b"/><text x="150" y="103" text-anchor="middle">DE</text>
    <rect x="176" y="88" width="44" height="22" fill="none" stroke="#1f5f8b"/><text x="198" y="103" text-anchor="middle">FR</text>
    <rect x="224" y="88" width="44" height="22" fill="none" stroke="#1f5f8b"/><text x="246" y="103" text-anchor="middle">PL</text>
    <rect x="272" y="88" width="44" height="22" fill="none" stroke="#1f5f8b"/><text x="294" y="103" text-anchor="middle">US</text>
    <text x="330" y="103" fill="#1f5f8b">no IE → "definitely not"</text>
  </g>
  <g font-size="11" fill="currentColor">
    <text x="10" y="140">Min/max only knows the ends of the range. The dictionary knows every value.</text>
    <text x="10" y="158">The reader decodes one small dictionary page instead of the data pages.</text>
  </g>
  <rect x="0" y="174" width="560" height="86" fill="#1f5f8b" fill-opacity="0.08"/>
  <g font-size="11.5" fill="currentColor">
    <text x="10" y="194" font-weight="700">Works for =, IN, and their negations, when:</text>
    <text x="10" y="212">· every page of the chunk is dictionary encoded (no fallback to PLAIN), and</text>
    <text x="10" y="230">· parquet.filter.dictionary.enabled is true (the default).</text>
    <text x="10" y="250" fill="#b8381f">High-cardinality columns fall back to PLAIN, so they need a bloom filter instead.</text>
  </g>
</svg>
<figcaption>Illustrative row group. In the scenario every row group holds all 20 countries, so this filter can't help there; it pays off when the data is clustered by the filtered column.</figcaption>
</figure>

<figure>
<svg viewBox="0 0 560 300" width="100%" style="max-width:560px" role="img" aria-label="Slide 6: a bloom filter hashes the lookup value to one 256-bit block and checks eight bits, one in each 32-bit word; if any bit is zero the value is definitely absent">
  <rect x="0" y="0" width="560" height="26" fill="#16252b"/>
  <text x="10" y="18" font-size="12" font-weight="700" fill="#f6f3ec">Slide 6 / 7 · d. Bloom filter</text>
  <text x="550" y="18" font-size="11" fill="#f6f3ec" text-anchor="end">WHERE user_id = 'u-4242'</text>
  <g font-size="11" fill="currentColor">
    <text x="10" y="50">user_id min/max is about u-1 … u-99999 in every row group, so min/max can't help.</text>
    <text x="10" y="76" font-family="JetBrains Mono, monospace">xxHash64('u-4242')</text>
    <text x="150" y="76">→ top 32 bits pick a block, the rest pick one bit in each of 8 words</text>
  </g>
  <text x="10" y="104" font-size="10.5" fill="currentColor">Block k (256 bits = 8 words × 32 bits)</text>
  <g stroke="#c9c2b4" fill="none">
    <rect x="10" y="112" width="540" height="24"/>
    <path d="M77.5 112V136M145 112V136M212.5 112V136M280 112V136M347.5 112V136M415 112V136M482.5 112V136"/>
  </g>
  <g fill="#1f5f8b">
    <rect x="30" y="116" width="6" height="16"/><rect x="100" y="116" width="6" height="16"/><rect x="160" y="116" width="6" height="16"/><rect x="236" y="116" width="6" height="16"/>
    <rect x="300" y="116" width="6" height="16"/><rect x="380" y="116" width="6" height="16"/><rect x="440" y="116" width="6" height="16"/>
  </g>
  <rect x="520" y="116" width="6" height="16" fill="none" stroke="#b8381f" stroke-width="2"/>
  <text x="523" y="152" font-size="10" fill="#b8381f" text-anchor="middle">0</text>
  <g font-size="11" fill="currentColor">
    <text x="10" y="176">7 of the 8 bits are set, but one is 0. If 'u-4242' had been written, all 8 would be set.</text>
    <text x="10" y="194" font-weight="700" fill="#1f5f8b">→ "definitely not in this row group": skip it.</text>
    <text x="10" y="214">If all 8 were set: "maybe" (a false positive is possible; a false negative is not).</text>
  </g>
  <rect x="0" y="228" width="560" height="72" fill="#1f5f8b" fill-opacity="0.08"/>
  <g font-size="11.5" fill="currentColor">
    <text x="10" y="248">Off by default. Enable per column: parquet.bloom.filter.enabled#user_id = true.</text>
    <text x="10" y="266">Size it with parquet.bloom.filter.expected.ndv#user_id. About 10 bits per</text>
    <text x="10" y="284">distinct value gives roughly a 1% false positive rate.</text>
  </g>
</svg>
<figcaption>Scenario result: <code>parquet bloom-filter</code> answers "NOT exists" for 51 of 53 row groups and "maybe" for 2, which both really contain u-4242. Spark decoded 76,880 rows instead of 2,000,000. Parquet uses a split block bloom filter: each value touches only one 32-byte block, so a lookup reads 8 bits from one small, contiguous block.</figcaption>
</figure>

<figure>
<svg viewBox="0 0 560 340" width="100%" style="max-width:560px" role="img" aria-label="Slide 7: in row groups 38 and 39, the column index gives min and max per page of event_date; only page 1 of row group 38 and page 0 of row group 39 can contain 2026-10-01; the offset index maps those row ranges to the same pages in the other columns">
  <rect x="0" y="0" width="560" height="26" fill="#16252b"/>
  <text x="10" y="18" font-size="12" font-weight="700" fill="#f6f3ec">Slide 7 / 7 · e. Page index: skip pages inside a row group</text>
  <text x="10" y="48" font-size="10.5" font-weight="700" fill="currentColor">Column index for event_date (min … max per page)</text>
  <g font-size="10" fill="currentColor" text-anchor="middle"><text x="140" y="66">RG 38</text><text x="420" y="66">RG 39</text></g>
  <g font-size="9.5" font-family="JetBrains Mono, monospace" fill="currentColor" text-anchor="middle">
    <rect x="10" y="72" width="128" height="36" fill="#c9c2b4" fill-opacity="0.4"/><text x="74" y="87">page 0</text><text x="74" y="101">09-24 … 09-28</text>
    <rect x="142" y="72" width="128" height="36" fill="#1f5f8b" fill-opacity="0.45" stroke="#1f5f8b"/><text x="206" y="87">page 1</text><text x="206" y="101">09-28 … 10-01</text>
    <rect x="290" y="72" width="128" height="36" fill="#1f5f8b" fill-opacity="0.45" stroke="#1f5f8b"/><text x="354" y="87">page 0</text><text x="354" y="101">10-01 … 10-05</text>
    <rect x="422" y="72" width="128" height="36" fill="#c9c2b4" fill-opacity="0.4"/><text x="486" y="87">page 1</text><text x="486" y="101">10-05 … 10-08</text>
  </g>
  <text x="10" y="132" font-size="10.5" font-weight="700" fill="currentColor">Offset index: first row of each page, then the same rows in the other columns</text>
  <g font-size="9.5" font-family="JetBrains Mono, monospace" fill="currentColor" text-anchor="middle">
    <text x="74" y="148">rows 0–19,999</text><text x="206" y="148">rows 20,000–38,439</text><text x="354" y="148">rows 0–19,999</text><text x="486" y="148">rows 20,000–38,439</text>
  </g>
  <g font-size="10" fill="currentColor"><text x="10" y="170">country</text><text x="10" y="194">user_id</text><text x="10" y="218">amount</text></g>
  <g fill="#c9c2b4" fill-opacity="0.4">
    <rect x="62" y="158" width="76" height="16"/><rect x="62" y="182" width="76" height="16"/><rect x="62" y="206" width="76" height="16"/>
    <rect x="422" y="158" width="128" height="16"/><rect x="422" y="182" width="128" height="16"/><rect x="422" y="206" width="128" height="16"/>
  </g>
  <g fill="#1f5f8b" fill-opacity="0.5">
    <rect x="142" y="158" width="128" height="16"/><rect x="142" y="182" width="128" height="16"/><rect x="142" y="206" width="128" height="16"/>
    <rect x="290" y="158" width="128" height="16"/><rect x="290" y="182" width="128" height="16"/><rect x="290" y="206" width="128" height="16"/>
  </g>
  <rect x="0" y="236" width="560" height="104" fill="#1f5f8b" fill-opacity="0.08"/>
  <g font-size="11.5" fill="currentColor">
    <text x="10" y="256">Pages here hold up to 20,000 rows (parquet-java's default row limit per page).</text>
    <text x="10" y="274">Only 2 of the 4 event_date pages can match, so the reader decodes 18,440 + 20,000</text>
    <text x="10" y="292">= 38,440 rows, not the 76,880 in both row groups. In general, page boundaries</text>
    <text x="10" y="310">differ between columns; the offset index keeps every column row-aligned.</text>
    <text x="10" y="332" font-weight="700" fill="#1f5f8b">Only the blue pages are read and decompressed.</text>
  </g>
</svg>
<figcaption>Real page ranges from <code>parquet column-index</code>, and the real 38,440 rows Spark decoded. Without the page index, a reader that needs one page has to walk every page header in the chunk.</figcaption>
</figure>

</div>

#### How the levels combine

<pre class="mermaid">
flowchart TD
    Q["Query with a filter"] --> P{"Partition column<br/>in the filter?"}
    P -- yes --> P1["List only matching<br/>directories"]
    P -- no --> F
    P1 --> F["For each file: read footer"]
    F --> RG{"For each row group"}
    RG --> S{"min/max or null_count<br/>rule it out?"}
    S -- yes --> X["Skip row group"]
    S -- no --> D{"Fully dictionary encoded<br/>and value not in dictionary?"}
    D -- yes --> X
    D -- no --> B{"Bloom filter present<br/>and says no?"}
    B -- yes --> X
    B -- no --> PI["Page index: keep only<br/>matching page ranges"]
    PI --> R["Read, decompress, decode<br/>surviving pages of needed columns"]
    R --> RF["Spark re-checks the filter<br/>on every row"]
</pre>

#### Bloom filters in practice

A bloom filter answers one question per row group: could this exact value be here? It's built for the case the other levels miss: **equality on a high-cardinality column** such as `user_id`, `order_id` or `trace_id`. Its min/max range covers almost everything, and the column is too varied to keep a dictionary.

| Setting (parquet-java writer option) | Default | What it does |
|--------------------------------------|---------|--------------|
| **`parquet.bloom.filter.enabled#<col>`** | `false` | Write a bloom filter for that column |
| **`parquet.bloom.filter.expected.ndv#<col>`** | not set | Distinct values to size the filter for. If unset, the filter uses the maximum size |
| **`parquet.bloom.filter.fpp#<col>`** | `0.01` | Target false positive probability |
| **`parquet.bloom.filter.max.bytes`** | 1 MB | Upper limit per filter |
| **`parquet.bloom.filter.adaptive.enabled`** | `false` | Try several sizes and keep the smallest that fits the real distinct count |
| **`parquet.filter.bloom.enabled`** (reader) | `true` | Use bloom filters when reading |

From Spark, pass them as write options:

```scala
events.write
  .option("parquet.bloom.filter.enabled#user_id", "true")
  .option("parquet.bloom.filter.expected.ndv#user_id", "40000")  // per row group, not per table
  .option("parquet.bloom.filter.fpp#user_id", "0.01")
  .parquet(path)
```

**Size it per row group.** There is one filter per column chunk, so the distinct count that matters is how many distinct values one row group holds. The scenario run set `expected.ndv` to 500,000, the table-wide count. Every one of the 53 row groups got a 1 MB filter (`bloomFilterLength: 1048594` in `parquet footer`), although each holds at most 38,440 rows. That is 53 MB of bloom filters on 107 MB of data. They still worked (51 of 53 row groups skipped), but they were more than ten times larger than they needed to be.

**What it can't do.** Ranges, `LIKE`, `IS NULL` and `!=` gain nothing from a bloom filter. It only says "definitely absent" for one exact value, and it never says "definitely present".

#### Null counts

Every column chunk also records `null_count`. `WHERE col IS NULL` skips row groups whose `null_count` is 0. `WHERE col IS NOT NULL` skips row groups where every value is null.

#### What can't be pushed down

The reader can only compare statistics against a **raw column and a literal**. Anything that changes the column's value before the comparison stays in Spark.

| Filter | Pushed to Parquet? | Why |
|--------|--------------------|-----|
| `country = 'IE'` | Yes | Column compared to a literal |
| `country IN ('IE', 'GB')` | Yes | Becomes a set of equality checks |
| `event_date >= '2026-10-01'` | Yes | Range check against min/max |
| `user_id IS NULL` | Yes | Uses `null_count` |
| `upper(country) = 'IE'` | No | The statistics are for `country`, not `upper(country)` |
| `myUdf(country)` | No | Spark can't reason about a UDF |
| `year(event_date) = 2026` | No | Function on the column; rewrite as a date range |
| `cast(amount as int) = 5` | No | Cast on the column; filter on the column's own type |
| `country LIKE '%E'` | No | Only prefix patterns (`LIKE 'I%'`) can use a range |

The rule of thumb is to keep the column bare on one side of the comparison.

### 4. Reading the Spark plan: PartitionFilters, PushedFilters, Filter

Spark prints the levels above as three different lines. Here is the real formatted plan for the partitioned table, with one extra filter, `upper(device) = 'IOS'`, that can't be pushed:

```scala
spark.read.parquet("/tmp/parquet-demo/events_by_date")
  .where($"event_date" === "2026-10-01" && $"country" === "IE" && upper($"device") === "IOS")
  .select("user_id", "country", "amount")
  .explain("formatted")
```

```
== Physical Plan ==
* Project (4)
+- * Filter (3)
   +- * ColumnarToRow (2)
      +- Scan parquet  (1)

(1) Scan parquet
Output [5]: [user_id#316, country#317, device#318, amount#319, event_date#332]
Batched: true
Location: InMemoryFileIndex [file:/tmp/parquet-demo/events_by_date]
PartitionFilters: [isnotnull(event_date#332), (event_date#332 = 2026-10-01)]
PushedFilters: [IsNotNull(country), IsNotNull(device), EqualTo(country,IE)]
ReadSchema: struct<user_id:string,country:string,device:string,amount:double>

(3) Filter [codegen id : 1]
Condition : (((isnotnull(country#317) AND isnotnull(device#318)) AND (country#317 = IE))
             AND (upper(device#318) = IOS))
```

*Trimmed: the `ColumnarToRow` and `Project` details are left out, and the `Filter` condition is wrapped.*

| Line in the plan | Applied by | When | Granularity | Exact? |
|------------------|-----------|------|-------------|--------|
| **`PartitionFilters`** | Spark, against directory names | While listing files, before any file is opened | Whole files | Yes |
| **`PushedFilters`** | The Parquet reader, against footer stats, dictionaries, bloom filters and the page index | Per file, before decoding pages | Row groups and pages | No: "maybe" survives |
| **`Filter`** (separate node above the scan) | Spark, on decoded rows | After the scan | Rows | Yes |

Four things to read from it:

1. **`PartitionFilters` has the date.** Only one directory is listed. The date doesn't appear in `PushedFilters` because the files don't contain that column.
2. **`PushedFilters` has `country` but not `upper(device)`.** Spark pushed `IsNotNull(device)`, which it derived itself, but not the comparison. A predicate missing from this list can't skip anything.
3. **`ReadSchema` includes `device`.** It isn't selected, but the Filter node needs it, so it is read.
4. **The `Filter` node repeats the pushed filters.** That isn't a mistake. Pushed filters only rule out blocks, so Spark still has to drop the non-matching rows inside the blocks that survived.

`PushedFilters` lists what Spark *handed* to the reader. It doesn't prove that anything was skipped. To see actual skipping, compare bytes and records read, as in the scenario table, or the **number of files read**, **size of files read** and **scan time** metrics on the scan node in the Spark UI's SQL tab.

### 5. Other things Parquet gives you

| Benefit | How |
|---------|-----|
| **Self-describing files** | The footer holds the schema with physical types (INT64, BYTE_ARRAY …) and logical types (DATE, TIMESTAMP, DECIMAL, STRING). No separate schema registry is needed to read a file. |
| **Nested data** | Structs, arrays and maps are stored as flat leaf columns, using **repetition levels** (which list a value belongs to) and **definition levels** (how much of an optional path is present). `select("address.city")` reads only that leaf column. |
| **Parallel reads of one file** | Spark splits files into chunks of up to `spark.sql.files.maxPartitionBytes` (128 MB). Each row group is read by the split that contains its midpoint, so a large file spreads over many tasks without any row group being read twice. |
| **Aggregates from metadata** | With `spark.sql.parquet.aggregatePushdown=true` (off by default), `COUNT`, `MIN` and `MAX` can be answered from footer statistics without reading data pages. |
| **Vectorized reading** | Spark's vectorized reader (`spark.sql.parquet.enableVectorizedReader`, on by default) decodes 4,096 rows per batch (`columnarReaderBatchSize`), a column at a time. |
| **Language neutral** | The format is an open spec with implementations in Java, C++, Rust and others, so the same files are readable by most query engines, not just Spark. |
| **Schema evolution, partly** | Adding a column is safe: older files return null for it. Spark merges schemas across files only when `mergeSchema=true` (off by default). Renames and drops need a table format (below). |

---

## How the Pieces Fit

<pre class="mermaid">
flowchart LR
    W["Writer<br/>sort → encode → compress"] --> FILE["Parquet file<br/>row groups · pages · footer"]
    FILE --> FT["Footer<br/>schema, offsets, min/max"]
    FT --> CP["Column pruning<br/>ReadSchema"]
    FT --> RS["Row group skipping<br/>min/max, null_count"]
    FILE --> DI["Dictionary pages"] --> RS
    FILE --> BF["Bloom filters"] --> RS
    FILE --> PIX["Page index"] --> PS["Page skipping"]
    CP --> RD["Ranged reads of<br/>surviving pages"]
    RS --> RD
    PS --> RD
    RD --> DEC["Decompress + decode<br/>(vectorized)"] --> FIL["Spark Filter<br/>exact rows"]
</pre>

---

## Inspecting a File with parquet-cli

The best way to learn Parquet is to write a file and look inside it. **parquet-cli** is the command-line tool that ships with parquet-java, the reference Java implementation that Spark uses. It replaced the older Java **parquet-tools**, which is deprecated (Homebrew no longer installs it). Several unrelated projects reuse the `parquet-tools` name, so check which one you have.

```bash
brew install parquet-cli          # installs the `parquet` command
```

| Command | Shows | Use it to learn |
|---------|-------|-----------------|
| `parquet meta <file>` | Every row group: row count, size, and per column the codec, encodings and min/max/nulls | Row group statistics, compression ratio per column |
| `parquet pages <file>` | Every page: type, encoding, size, value count | Dictionary pages, dictionary fallback, page sizes |
| `parquet dictionary -c country <file>` | The dictionary for a column, per row group | Exactly what the dictionary filter checks |
| `parquet column-index -c event_date <file>` | The column index and offset index | Page-level min/max and row offsets |
| `parquet bloom-filter -c user_id -v u-4242 <file>` | Whether a value might be present, per row group | Bloom filter answers |
| `parquet footer <file>` | The whole footer as JSON | Every field the reader sees |
| `parquet schema <file>` | The schema | Types and nesting |
| `parquet column-size <file>` | Bytes per column | Which columns cost the most |

Run against the files from the scenario:

```bash
F=$(ls /tmp/parquet-demo/events_sorted/*.parquet)
```

**`parquet meta`**: one block per row group. This is row group 38 of the sorted file, the one that holds the end of September (some columns removed):

```
Row group 38:  count: 38440  53.65 B records  start: 78351620  total(compressed): 1.967 MB total(uncompressed):3.054 MB
--------------------------------------------------------------------------------
            type      encodings count     avg size   nulls   min / max
event_id    INT64     S   _     38440     5.06 B     0       "21" / "1999976"
event_ts    INT96     S _ R     38440     8.90 B     0
event_date  INT32     S _ R     38440     0.00 B     0       "2026-09-24" / "2026-10-01"
user_id     BINARY    S   _     38440     6.12 B     0       "u-1" / "u-9999"
country     BINARY    S _ R     38440     0.02 B     0       "AT" / "US"
device      BINARY    S _ R     38440     0.26 B     0       "android" / "web"
```

Under encodings, `S` is the snappy codec, `R` is a dictionary-encoded column and `_` is plain. `user_id` has no `R`: with mostly distinct ids, the writer didn't keep a dictionary and wrote the column plain. `event_ts` has no min/max, because it is INT96. `event_date` averages 0.00 bytes per value: one week of sorted dates is a handful of runs.

**`parquet pages -c country`**: the dictionary page (`dict`) and the data pages of each column chunk:

```
  page   type  enc  count   avg size   size       rows     nulls   min / max
  0-D    dict  S _  20      6.00 B     120 B
  0-1    data  S R  20000   0.01 B     232 B
  0-2    data  S R  18440   0.01 B     220 B
```

20,000 country values fit in 232 bytes, because they're sorted runs of 20 dictionary ids.

**`parquet column-index -c event_date`**: what the page index stores for row group 38 (columns trimmed):

```
column index for column event_date:
Boundary order: ASCENDING
                      null count  min                                       max
page-0                         0  2026-09-24                                2026-09-28
page-1                         0  2026-09-28                                2026-10-01

offset index for column event_date:
                          offset       compressed size       first row index
page-0                  78888480                    51                     0
page-1                  78888531                    48                 20000
```

**`parquet bloom-filter -c user_id -v u-4242`**: one answer per row group:

```
Row group 3:
--------------------------------------------------------------------------------
value u-4242 NOT exists.

Row group 4:
--------------------------------------------------------------------------------
value u-4242 maybe exists.
```

51 row groups answer "NOT exists" and 2 answer "maybe".

**`parquet dictionary -c country`**: the exact values the dictionary filter checks:

```
Row group 0 dictionary for "country":
     0: "AT"
     1: "AU"
     2: "BE"
     3: "CA"
     ...
```

**Is this the best way to learn?** For the internals, yes. Each command matches one mechanism from this post, and the output uses the format's own names: row groups, encodings, column index, bloom filter. Writing the same data sorted and unsorted, then comparing `parquet meta` side by side, teaches more about data skipping than any diagram. For everyday checks on production tables, the Spark plan and the SQL tab metrics are quicker, because they show what the query actually did.

---

## What Delta Lake and Iceberg Add on Top

Delta and Iceberg tables are directories of ordinary Parquet files plus a metadata layer. Everything above still happens inside each file. The metadata layer adds a level above the files and fixes the weaknesses of plain Parquet.

<pre class="mermaid">
flowchart TD
    Q["Query"] --> M["Table metadata<br/>Delta: _delta_log · Iceberg: manifests"]
    M -- "per-file min/max, null counts<br/>skip whole files without opening them" --> F["Surviving Parquet files"]
    F --> FT["Parquet footer<br/>row group min/max, dictionary, bloom"]
    FT --> PG["Page index"]
    PG --> RF["Row filter in the engine"]
</pre>

| Parquet feature | Plain Parquet | Delta Lake | Apache Iceberg |
|-----------------|---------------|------------|----------------|
| **Data files** | Parquet | Parquet | Parquet by default (`write.format.default`); ORC and Avro also allowed |
| **Min/max at file level** | Not stored anywhere central; the reader must open every footer | `minValues`, `maxValues`, `nullCount`, `numRecords` per file in the transaction log | `lower_bounds`, `upper_bounds`, `null_value_counts`, `value_counts` per file in manifests |
| **Which columns get stats** | Every column, in every footer | First 32 columns by default (`delta.dataSkippingNumIndexedCols`) | First 100 columns by default (`write.metadata.metrics.max-inferred-column-defaults`) |
| **String stats truncation** | parquet-java truncates column index values to 64 bytes | Strings cut to a fixed prefix | `truncate(16)` by default (`write.metadata.metrics.default`) |
| **Partition pruning** | Directory names (Hive style) | Partition values stored in the log | Hidden partitioning: transforms such as `days(ts)`, so filters on `ts` prune without a separate date column |
| **Skipping depends on sort order** | Yes | Yes: Z-order and liquid clustering keep file ranges narrow | Yes: sort orders and Z-order in `rewrite_data_files` |
| **Bloom filters** | `parquet.bloom.filter.enabled#col` | Not part of the Delta protocol | `write.parquet.bloom-filter-enabled.column.<col>` |
| **Column rename and drop** | Columns matched by name; a rename breaks old files | Column mapping stores a physical name and a Parquet `field_id` | Columns matched by Parquet `field_id`, always |
| **Updates and deletes** | Files are immutable; rewrite the file | Deletion vectors mark deleted rows; files rewritten later | Positional and equality delete files, or deletion vectors in v3 |
| **Atomic commits, time travel** | None | Yes, via the log | Yes, via snapshots |
| **Default codec** | snappy (Spark) | snappy (Spark) | zstd |
| **Row group size** | 128 MB (parquet-java) | 128 MB (parquet-java) | 128 MB (`write.parquet.row-group-size-bytes`), with 512 MB target files |

The biggest change is the first data row. With plain Parquet on object storage, a query over 10,000 files must issue at least 10,000 footer reads before it skips anything. Delta and Iceberg keep the same min/max values in a few metadata files, so the planner drops most files before opening any of them. Inside the files that remain, the Parquet mechanisms in this post still do the rest.

---

## Where It Hurts

| Watch-out | Why it matters | What to do |
|-----------|----------------|------------|
| **Unsorted data** | Every row group spans the full range, so min/max skips nothing | Sort within partitions on the main filter columns before writing |
| **Many small files** | One footer read and one task per file; row groups too small to compress well | Compact into larger files; Delta and Iceberg have `OPTIMIZE` and `rewrite_data_files` |
| **Functions on filter columns** | Not pushed, so nothing is skipped | Rewrite as a range on the raw column |
| **High-cardinality equality filters** | Dictionary falls back to PLAIN; min/max too wide | Add a bloom filter on that column, or sort by it |
| **Long string columns** | Statistics are truncated, so ranges become fuzzy | Filter on shorter keys; don't rely on skipping for long strings |
| **Too many partition values** | One directory per value means tiny files | Partition only on low-cardinality columns, usually dates |
| **`SELECT *` everywhere** | Column pruning does nothing | Select columns as early as possible |
| **Bloom filter sized for the whole table** | One filter per row group; an oversized NDV gives every row group a 1 MB filter | Set `expected.ndv` to the distinct count of one row group, or enable adaptive sizing |
| **INT96 timestamps (Spark's default)** | No min/max is written, so timestamp filters skip nothing | Set `spark.sql.parquet.outputTimestampType=TIMESTAMP_MICROS` |
| **Updating rows** | Parquet files can't be changed in place | Use Delta or Iceberg, which rewrite or mark rows for you |
| **Schema drift across files** | Spark reads one file's schema unless `mergeSchema=true` | Use a table format, or merge schemas explicitly |

---

## When Something Else Fits Better

| Situation | Better fit | Why |
|-----------|------------|-----|
| **Writing one record at a time (Kafka, CDC streams)** | Avro | Row format: cheap to append a record, schema per message |
| **Reading whole rows by key** | A database or key-value store | Parquet is built for scanning columns, not point lookups |
| **Small files exchanged with people or other tools** | CSV or JSON | Human-readable; size doesn't matter |
| **Hive-centric stacks** | ORC | Similar columnar design with its own stats and indexes |
| **Updates, deletes, concurrent writers, time travel** | Delta Lake or Iceberg (on Parquet) | Adds a transaction log and file-level statistics |

<pre class="mermaid">
flowchart TD
    A["New dataset"] --> B{"Mostly analytical scans<br/>over many rows?"}
    B -- no --> B1["Row format (Avro) or a database"]
    B -- yes --> C{"Need updates, deletes,<br/>or concurrent writers?"}
    C -- yes --> C1["Delta Lake or Iceberg<br/>(Parquet underneath)"]
    C -- no --> D["Plain Parquet"]
    C1 --> E["Sort or cluster on the<br/>main filter columns"]
    D --> E
    E --> F{"Equality filters on<br/>high-cardinality ids?"}
    F -- yes --> F1["Add bloom filters"]
    F -- no --> G["Done"]
    F1 --> G
</pre>

---

## Checking It Works

1. **Read the plan.** Run `df.explain("formatted")`. Check that `ReadSchema` lists only the columns you need, and that your filter columns appear in `PartitionFilters` or `PushedFilters`.
2. **Compare bytes read.** On the Spark UI's SQL tab, compare the scan node's **size of files read** and output rows against a full scan. Skipping works if a selective filter reads a small share of the bytes.
3. **Inspect the file.** Run `parquet meta` and check that the filter column's min/max ranges are narrow and don't overlap across row groups. Wide, overlapping ranges mean the data needs sorting.
4. **Check special cases.** For bloom filters, `parquet bloom-filter -c <col> -v <value>` should say "no" for most row groups. For dictionaries, `parquet pages` should show no PLAIN data pages in the filter column.

---

## Reproduce It

The script that produced every number above. Save it as `parquet-demo.scala` and run it with `spark-shell --master "local[4]" --driver-memory 4g -i parquet-demo.scala`.

```scala
// spark-shell --master "local[4]" --driver-memory 4g -i parquet-demo.scala
import org.apache.spark.sql.functions._
import org.apache.spark.scheduler._
import java.util.concurrent.atomic.AtomicLong

def runDemo(): Unit = {
val out = "/tmp/parquet-demo"   // about 750 MB in total
spark.sparkContext.setLogLevel("ERROR")

val countries = Array("IE","GB","US","DE","FR","ES","IT","NL","SE","PL","PT","BE","AT","DK","FI","NO","CH","CA","AU","JP")
val countryCol = element_at(typedLit(countries), (pmod(xxhash64(col("id"), lit(7)), lit(countries.length)) + 1).cast("int"))

// 2M events across 2026, plus 12 filler columns so the table is wide (19 columns)
val base = spark.range(0, 2000000L, 1, 8)
  .withColumn("event_ts", timestamp_seconds(lit(1767225600L) + pmod(xxhash64(col("id"), lit(1)), lit(365L * 86400))))
  .withColumn("event_date", to_date(col("event_ts")))
  .withColumn("user_id", concat(lit("u-"), pmod(xxhash64(col("id"), lit(2)), lit(500000L)).cast("string")))
  .withColumn("country", countryCol)
  .withColumn("device", element_at(typedLit(Array("ios","android","web")), (pmod(col("id"), lit(3)) + 1).cast("int")))
  .withColumn("amount", round(pmod(xxhash64(col("id"), lit(3)), lit(100000L)) / 100.0, 2))
  .withColumnRenamed("id", "event_id")
val wide = (1 to 12).foldLeft(base)((df, i) => df.withColumn(s"attr_$i", concat(lit(s"a$i-"), pmod(xxhash64(col("event_id"), lit(10 + i)), lit(1000L * i)).cast("string"))))

// Small row groups so one file has many of them (default is 128 MB)
spark.sparkContext.hadoopConfiguration.setInt("parquet.block.size", 4 * 1024 * 1024)

wide.repartition(1).write.mode("overwrite").parquet(s"$out/events_unsorted")
wide.repartition(1).sortWithinPartitions("event_date", "country").write.mode("overwrite")
  .option("parquet.bloom.filter.enabled#user_id", "true")
  .option("parquet.bloom.filter.expected.ndv#user_id", "500000")
  .parquet(s"$out/events_sorted")
wide.repartition(col("event_date")).sortWithinPartitions("country").write.mode("overwrite")
  .partitionBy("event_date").parquet(s"$out/events_by_date")
wide.repartition(1).write.mode("overwrite").option("header", "true").csv(s"$out/events_csv")

// Sum input bytes and records (rows decoded) over every task of the next action
val bytes = new AtomicLong; val recs = new AtomicLong
spark.sparkContext.addSparkListener(new SparkListener {
  override def onTaskEnd(e: SparkListenerTaskEnd): Unit = if (e.taskMetrics != null) {
    bytes.addAndGet(e.taskMetrics.inputMetrics.bytesRead); recs.addAndGet(e.taskMetrics.inputMetrics.recordsRead)
  }
})
def measure(label: String)(f: => Long): Unit = {
  bytes.set(0); recs.set(0)
  val n = f
  Thread.sleep(1500)
  println(f"RESULT | $label%-38s | rows=$n%,9d | bytesRead=${bytes.get / 1024.0 / 1024}%,8.1f MiB | recordsRead=${recs.get}%,10d")
}

val ieOct1 = col("event_date") === "2026-10-01" && col("country") === "IE"
val cols = Seq("user_id", "country", "amount").map(col)

measure("csv: 3 cols, date+country") { spark.read.option("header", "true").csv(s"$out/events_csv").where(ieOct1).select(cols: _*).count() }
measure("parquet unsorted: 3 cols") { spark.read.parquet(s"$out/events_unsorted").where(ieOct1).select(cols: _*).collect().length.toLong }
measure("parquet sorted: 3 cols") { spark.read.parquet(s"$out/events_sorted").where(ieOct1).select(cols: _*).collect().length.toLong }
measure("parquet sorted: pushdown off") {
  spark.conf.set("spark.sql.parquet.filterPushdown", "false")
  val n = spark.read.parquet(s"$out/events_sorted").where(ieOct1).select(cols: _*).collect().length.toLong
  spark.conf.set("spark.sql.parquet.filterPushdown", "true"); n
}
measure("parquet partitioned: 3 cols") { spark.read.parquet(s"$out/events_by_date").where(ieOct1).select(cols: _*).collect().length.toLong }
measure("sorted: upper(country) = 'IE'") { spark.read.parquet(s"$out/events_sorted").where(col("event_date") === "2026-10-01" && upper(col("country")) === "IE").select(cols: _*).collect().length.toLong }
measure("unsorted: user_id = u-4242") { spark.read.parquet(s"$out/events_unsorted").where(col("user_id") === "u-4242").select(cols: _*).collect().length.toLong }
measure("sorted+bloom: user_id = u-4242") { spark.read.parquet(s"$out/events_sorted").where(col("user_id") === "u-4242").select(cols: _*).collect().length.toLong }

println("PLAN-PARTITIONED")
spark.read.parquet(s"$out/events_by_date").where(ieOct1 && upper(col("device")) === "IOS").select(cols: _*).explain("formatted")
println("PLAN-END")

}
runDemo()
System.exit(0)
```

Then run the parquet-cli commands above on the files under `/tmp/parquet-demo`. The whole run needs about 750 MB of free disk.

---

## What's Next

| Topic | What it builds on from this post |
|-------|----------------------------------|
| [How Iceberg achieves all-or-nothing writes]({% post_url 2024-12-09-How-does-Iceberg-Achieve-All-Or-Nothing-Writes %}) | Immutable Parquet files, plus a metadata layer that commits them atomically |
| [Liquid clustering under the hood]({% post_url 2026-10-26-Liquid-Clustering-Under-The-Hood %}) | Keeping per-file min/max ranges narrow as data keeps arriving |

---

## Sources

Checked on 2026-10-29.

| Source | Used for |
|--------|----------|
| [Parquet file format](https://parquet.apache.org/docs/file-format/) | File layout, PAR1 magic, footer after the data for single-pass writing |
| [Parquet configurations](https://parquet.apache.org/docs/file-format/configurations/) | Recommended row group size (512 MB – 1 GB) |
| [Parquet data pages](https://parquet.apache.org/docs/file-format/data-pages/) | Page contents: repetition levels, definition levels, values |
| [Parquet encodings](https://parquet.apache.org/docs/file-format/data-pages/encodings/) | PLAIN, RLE_DICTIONARY, RLE/bit-packing, delta encodings, BYTE_STREAM_SPLIT, dictionary fallback |
| [Parquet page index](https://parquet.apache.org/docs/file-format/pageindex/) | ColumnIndex and OffsetIndex, storage near the footer, why page headers alone weren't enough |
| [Parquet bloom filter](https://parquet.apache.org/docs/file-format/bloomfilter/) | Split block bloom filter, xxHash64, 256-bit blocks, false positive rates, location in file |
| [parquet-hadoop README](https://github.com/apache/parquet-java/blob/master/parquet-hadoop/README.md) | `parquet.block.size`, page size, row count limit, dictionary page size, bloom filter options, column index truncation, filter level switches |
| [parquet-cli README](https://github.com/apache/parquet-java/blob/master/parquet-cli/README.md) | Commands and their descriptions |
| [`DictionaryFilter.java`](https://github.com/apache/parquet-java/blob/master/parquet-hadoop/src/main/java/org/apache/parquet/filter2/dictionarylevel/DictionaryFilter.java) | Dictionary filter only applies when the chunk has no non-dictionary pages |
| [`ParquetMetadataConverter.java`](https://github.com/apache/parquet-java/blob/master/parquet-hadoop/src/main/java/org/apache/parquet/format/converter/ParquetMetadataConverter.java) | Row groups assigned to splits by midpoint |
| [Spark Parquet files](https://spark.apache.org/docs/latest/sql-data-sources-parquet.html) | `filterPushdown`, `compression.codec`, vectorized reader, batch size, `mergeSchema`, `aggregatePushdown` |
| [Spark performance tuning](https://spark.apache.org/docs/latest/sql-performance-tuning.html) | `spark.sql.files.maxPartitionBytes` |
| [SPARK-26345](https://issues.apache.org/jira/browse/SPARK-26345), [SPARK-34859](https://issues.apache.org/jira/browse/SPARK-34859) | Column index (page) filtering in Spark's Parquet readers |
| [Delta Lake protocol](https://github.com/delta-io/delta/blob/master/PROTOCOL.md) | Per-file statistics in the log, string truncation, column mapping and `field_id`, deletion vectors |
| [Delta table properties](https://docs.delta.io/latest/table-properties.html) | `delta.dataSkippingNumIndexedCols` default 32 |
| [Iceberg table spec](https://iceberg.apache.org/spec/) | Manifest bounds and counts, Parquet field IDs |
| [Iceberg configuration](https://iceberg.apache.org/docs/latest/configuration/) | Parquet defaults (zstd, 128 MB row groups, bloom filters), metrics mode `truncate(16)`, 100-column metrics default, 512 MB target file size |
