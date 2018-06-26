---
layout: post
title: Spark Structured Streaming - Writing to Elasticsearch (6.x) + Docker 
comments: true
---

Spark Structured Streaming - Writing to Elasticsearch 6.x

If you are using the version of Elasticsearch 6.x or above, writing to it in `Spark Structured Sreaming` is relatively straightforward.

Unlike previous versions like 5.x where you have to implement a custom sink to be able to write to Elasticsearch, version 6.x comes with Spark Structured Streaming support out of the box.

Dependencies required:
```
    <dependency>
        <groupId>org.elasticsearch</groupId>
        <artifactId>elasticsearch-spark-20_2.11</artifactId>
        <version>6.2.4</version>
    </dependency>
    <dependency>
        <groupId>org.apache.spark</groupId>
        <artifactId>spark-core_${scala.main}</artifactId>
        <version>2.3.1</version>
    </dependency>
    <dependency>
        <groupId>org.apache.spark</groupId>
        <artifactId>spark-sql_${scala.main}</artifactId>
        <version>2.3.1</version>
    </dependency>
    <dependency>
        <groupId>org.apache.spark</groupId>
        <artifactId>spark-streaming_${scala.main}</artifactId>
        <version>2.3.1</version>
    </dependency>
```


Then it is as simple as;

## 1. Create the `SparkSession` with the Elasticsearch configuration
```
val spark = SparkSession
  .builder
  // run app locally utilizing all cores
  .master("local[*]")
  .appName(getClass.getName)
  .config("es.nodes", "localhost")
  .config("es.port", "9200")
  .config("es.index.auto.create", "true") // this will ensure that index is also created on first POST
  .config("es.nodes.wan.only", "true") // needed to run against dockerized ES for local tests
  .config("es.net.http.auth.user", "elastic")
  .config("es.net.http.auth.pass", "changeme")
  .getOrCreate()
```

## 2. Read from your socket source:
```
import spark.implicits._

val customerEvents: Dataset[Customer] = spark
  .readStream
  .format("socket")
  .option("host", "localhost")
  .option("port", "5555")
  // maximum number of lines processed per trigger interval
  .option("maxFilesPerTrigger", 5)
  .load()
  .as[String]
  .map(line => {
    val cols = line.split(",")
    val age = cols(2).toInt
    Customer(cols(0), cols(1), age, age > 18, System.currentTimeMillis())
  })
```

## 3. Write to Elasticsearch sink:
```
customerEvents
  .writeStream
  .outputMode(OutputMode.Append())
  .format("es")
  .option("checkpointLocation", "/tmp/checkpointLocation")
  .option("es.mapping.id", "id")
  .trigger(Trigger.ProcessingTime(5, TimeUnit.SECONDS))
  .start("customer/profile")
  .awaitTermination()
```

### Full code:
[Github](https://github.com/joeyfaherty/es6writer/blob/master/src/main/scala/com/joeyfaherty/spark/structured/streaming/ESWriter6.scala)

### Advanced:
If you want to see events being updated in real-time from your local machine to a Elasticsearch docker instance, follow the steps in the readme file on GIT.