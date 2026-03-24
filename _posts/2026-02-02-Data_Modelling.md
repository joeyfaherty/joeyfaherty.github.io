---
layout: post
title: "Data Modelling: Cardinality and Relationships"
comments: true
---

## What is Cardinality?

Cardinality describes **how many rows in one table can relate to rows in another table**. It is the foundation of every relational and analytical data model.

Common notations:

| Notation   | Meaning                          |
|------------|----------------------------------|
| `(1)`      | Exactly one                      |
| `(0..1)`   | Zero or one (optional)           |
| `(1..N)`   | One or many (at least one)       |
| `(0..N)`   | Zero, one, or many (optional)    |

---

## Example: E-Commerce Data Model

Consider a simple e-commerce platform. A **customer** places **orders**, each order contains **order lines**, and each line references a **product**.

<div class="mermaid" markdown="0">
erDiagram
    CUSTOMER ||--o{ ORDER : places
    ORDER ||--|{ ORDER_LINE : contains
    ORDER_LINE }o--|| PRODUCT : references
    PRODUCT }o--|| CATEGORY : belongs_to

    CUSTOMER {
        int customer_id PK
        string name
        string email
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
        decimal unit_price
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
</div>

---

## Reading the Diagram

| Relationship                  | Cardinality | Meaning                                      |
|-------------------------------|-------------|----------------------------------------------|
| Customer → Order              | `1` to `0..N` | A customer can place zero or many orders     |
| Order → Order Line            | `1` to `1..N` | An order must have at least one line item    |
| Order Line → Product          | `N` to `1`    | Many order lines can reference the same product |
| Product → Category            | `N` to `1`    | Many products belong to one category         |

---

## Why This Matters

Getting cardinality right affects everything downstream:

- **JOIN correctness** — a wrong cardinality assumption leads to duplicated or missing rows
- **Aggregation accuracy** — summing `total_amount` after a fan-out JOIN inflates numbers
- **Partition design** — in Iceberg/Delta Lake, partition keys follow the `(1)` side of relationships
- **Slowly Changing Dimensions** — cardinality determines whether you need SCD Type 1, 2, or 3

A solid data model is the foundation of a reliable data platform.

