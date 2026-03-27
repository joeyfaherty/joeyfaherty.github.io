---
layout: post
title: "Data Modelling: Cardinality, Relationships and Compression"
comments: true
---

## Relationship Cardinality

Cardinality defines how rows in one table relate to rows in another.

| Notation | Meaning |
|----------|---------|
| `1:1` | Exactly one to one |
| `1:N` | One to many |
| `N:M` | Many to many |
| `0..N` | Optional, zero or many |

---

## Example: E-Commerce Model

A **customer** places **orders**. Each order has **line items** referencing **products** in a **category**.

<pre class="mermaid">
erDiagram
    CUSTOMER ||--o{ ORDER : "1:N"
    ORDER ||--|{ ORDER_LINE : "1:N"
    ORDER_LINE }o--|| PRODUCT : "N:1"
    PRODUCT }o--|| CATEGORY : "N:1"
    CUSTOMER {
        int customer_id PK
        string name
        string country
    }
    ORDER {
        int order_id PK
        int customer_id FK
        date order_date
        decimal total_amount
    }
    ORDER_LINE {
        int line_id PK
        int order_id FK
        int product_id FK
        int quantity
    }
    PRODUCT {
        int product_id PK
        int category_id FK
        string name
        decimal price
    }
    CATEGORY {
        int category_id PK
        string name
    }
</pre>

---

## Reading the Relationships

| Relationship | Type | Meaning |
|---|---|---|
| Customer → Order | `1:N` | One customer, many orders |
| Order → Order Line | `1:N` | One order, many line items |
| Order Line → Product | `N:1` | Many lines reference one product |
| Product → Category | `N:1` | Many products in one category |

**Why this matters:** a `1:N` JOIN fans out rows. If you `SUM(total_amount)` after joining orders to order lines, you get **inflated totals**. Always aggregate before joining, or join on the `1` side.

---

## Column Cardinality and Parquet Compression

**Column cardinality** = the number of **distinct values** in a column. This directly impacts how well Parquet compresses your data.

<pre class="mermaid">
quadrantChart
    title Column Cardinality vs Compression
    x-axis "Low Cardinality" --> "High Cardinality"
    y-axis "Poor Compression" --> "Great Compression"
    country: [0.2, 0.85]
    status: [0.15, 0.9]
    category_id: [0.3, 0.75]
    order_date: [0.55, 0.5]
    product_id: [0.7, 0.35]
    email: [0.85, 0.15]
    event_id: [0.95, 0.1]
</pre>

---

## How Parquet Compression Works

Parquet stores data **column-by-column**, not row-by-row. Columns with few distinct values compress extremely well because repeated values are encoded efficiently.

<pre class="mermaid">
block-beta
    columns 3
    block:row["Row-Oriented (CSV/JSON)"]:3
        r1["Alice, IE, checkout, evt_1"]
        r2["Bob, DE, login, evt_2"]
        r3["Alice, IE, checkout, evt_3"]
    end
    space:3
    block:col["Column-Oriented (Parquet)"]:3
        c1["name: Alice, Bob, Alice"]
        c2["country: IE, DE, IE"]
        c3["event_id: evt_1, evt_2, evt_3"]
    end
</pre>

---

## Encoding by Cardinality

| Column | Distinct Values | Cardinality | Parquet Encoding | Compression |
|---|---|---|---|---|
| `country` | ~200 | Very low | **Dictionary** | Excellent |
| `status` | 3-5 | Very low | **RLE + Dictionary** | Excellent |
| `order_date` | ~365/year | Low | **Dictionary + Delta** | Good |
| `product_id` | ~10K | Medium | **Dictionary** | Moderate |
| `email` | ~1 per row | High | **Plain** | Poor |
| `event_id` | 1 per row | Unique | **Plain** | None |

**Dictionary encoding**: Parquet builds a lookup table of distinct values and stores integer indices instead of full values. A `country` column with 1 billion rows but only 200 distinct values stores just 200 strings + 1B tiny integers.

**RLE (Run-Length Encoding)**: If data is **sorted**, consecutive identical values are stored as `(value, count)`. Sorting by `country` before writing turns `IE, IE, IE, IE` into `(IE, 4)`.

---

## Practical Advice

**Sort before write** — sorting by low-cardinality columns maximises RLE compression:

```sql
-- Iceberg: sorted by low-cardinality columns first
ALTER TABLE orders WRITE ORDERED BY (country, status, order_date);
```

**Partition by low cardinality** — Iceberg/Delta partition keys should be low-cardinality columns (`country`, `event_date`), never high-cardinality (`user_id`, `event_id`).

**Column pruning** — Parquet reads only requested columns. High-cardinality columns like `event_id` don't hurt queries that don't select them.

| Action | Impact |
|---|---|
| Sort by low-cardinality columns | 2-5x smaller files |
| Partition by date/region | Faster query pruning |
| Avoid `SELECT *` | Skip high-cardinality columns |
| Use Zstandard compression | Better ratio than Snappy |
