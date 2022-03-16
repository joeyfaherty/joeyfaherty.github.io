---
layout: post
title: Handling Duplicates in Spark - Multiple Use Cases
comments: true
---

```
val teamsDs = spark.read
.option("inferSchema", "true")
.json("src/main/resources/data/teamsWithDuplicates.json")
.as[Team]

teamsDs.show()
```

As we can see our dataset has 6 rows, and for id 0 we have 3 duplicates.

2 exact duplicates and another that has a appointedTime later than the other two.

```
+-------------+-------+---+-----------------+---------+
|appointedTime|country|id |manager          |name     |
+-------------+-------+---+-----------------+---------+
|2016-10-01   |England|0  |Jurgen Klopp     |Liverpool|
|2016-10-01   |England|0  |Jurgen Klopp     |Liverpool|
|2016-10-02   |England|0  |Jurgen Klopp     |Liverpool|
|2021-05-01   |France |1  |Pochetino        |PSG      |
|2020-10-01   |Italy  |2  |Luciano Spalletti|Napoli   |
|2012-06-01   |England|3  |Pep Guardiola    |Man City |
+-------------+-------+---+-----------------+---------+
```

## Use case 1a - Removing exact duplicates with distinct()

```
  // distinct is identical to dropDuplicates.
  // it is an alias as we see in this Spark source code dropDuplicates.
  // def distinct(): Dataset[T] = dropDuplicates()
  teamsDs.distinct().show()
```

```
+-------------+-------+---+-----------------+---------+
|appointedTime|country| id|          manager|     name|
+-------------+-------+---+-----------------+---------+
|   2016-10-01|England|  0|     Jurgen Klopp|Liverpool|
|   2012-06-01|England|  3|    Pep Guardiola| Man City|
|   2020-10-01|  Italy|  2|Luciano Spalletti|   Napoli|
|   2021-05-01| France|  1|        Pochetino|      PSG|
|   2016-10-02|England|  0|     Jurgen Klopp|Liverpool|
+-------------+-------+---+-----------------+---------+
```

## Use case 1b - Removing exact duplicates with dropDuplicates()

```
  // returns a new DS that contains only unique rows
  // any 2 rows that are identical, (for every column), one will be dropped
  teamsDs.dropDuplicates().show()
```

```
+-------------+-------+---+-----------------+---------+
|appointedTime|country| id|          manager|     name|
+-------------+-------+---+-----------------+---------+
|   2016-10-01|England|  0|     Jurgen Klopp|Liverpool|
|   2012-06-01|England|  3|    Pep Guardiola| Man City|
|   2020-10-01|  Italy|  2|Luciano Spalletti|   Napoli|
|   2021-05-01| France|  1|        Pochetino|      PSG|
|   2016-10-02|England|  0|     Jurgen Klopp|Liverpool|
+-------------+-------+---+-----------------+---------+
```

## Use case 2 - Removing duplicates based on a column(s) with dropDuplicates(colName: String)

```
  // will only drop records that have the unique id columns
  teamsDs.dropDuplicates("id").show()
```

```
+-------------+-------+---+-----------------+---------+
|appointedTime|country| id|          manager|     name|
+-------------+-------+---+-----------------+---------+
|   2016-10-01|England|  0|     Jurgen Klopp|Liverpool|
|   2021-05-01| France|  1|        Pochetino|      PSG|
|   2020-10-01|  Italy|  2|Luciano Spalletti|   Napoli|
|   2012-06-01|England|  3|    Pep Guardiola| Man City|
+-------------+-------+---+-----------------+---------+
```


But, what if you only the latest record in the system is the correct record?
If we get 3 duplicates (by id), but one has a later timestamp than the others
Usually, the latest record would be the correct version.
In this case we need to create a better way to handle these duplicates

## Use case 3 -   

```
  // create a Window partitioned by id, ordered by latest (desc) appointedTime
  val window = Window.partitionBy("id").orderBy($"appointedTime".desc)
  // non duplicate rows will have rank = 1
  // duplicate rows will be ranked by appointedTime, with latest appointedTime = 1
  // and later duplicate records going from 2,3,4... etc
  val rankedByDuplicates = teamsDs.withColumn("rank", row_number().over(window))
  // only keep results that have a rank of 1
  // any results > 1 will be duplicates and filtered
  // leaving only latest duplicate record
  rankedByDuplicates.filter($"rank"  === 1).show()
```

```
+-------------+-------+---+-----------------+---------+----+
|appointedTime|country| id|          manager|     name|rank|
+-------------+-------+---+-----------------+---------+----+
|   2016-10-02|England|  0|     Jurgen Klopp|Liverpool|   1|
|   2021-05-01| France|  1|        Pochetino|      PSG|   1|
|   2020-10-01|  Italy|  2|Luciano Spalletti|   Napoli|   1|
|   2012-06-01|England|  3|    Pep Guardiola| Man City|   1|
+-------------+-------+---+-----------------+---------+----+
```