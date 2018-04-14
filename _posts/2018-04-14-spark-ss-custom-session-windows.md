---
layout: post
title: Spark Structured Streaming - Custom Session Windows
comments: true
---



[Spark Structured Streaming](https://spark.apache.org/docs/latest/structured-streaming-programming-guide.html) () allows us to perform aggregations 

> over a sliding event-time window in a straightforward manner
 
out of the box using  [windowing operation on event time](https://spark.apache.org/docs/latest/structured-streaming-programming-guide.html#window-operations-on-event-time) and [watermarking](https://spark.apache.org/docs/latest/structured-streaming-programming-guide.html#handling-late-data-and-watermarking).  

## Use case
* Continue to sum the wins of a user for the duration of the session, and when there is a deposit event in the stream, deposit the current balance and close the session. 

Windowing and watermarking by default work with time based windows.  In our use case this does not work as we want to close the session when we get a signal to deposit the current balance.

We can achieve this by implementing a custom session window based on the mapGroupsWithState function




### Step 0: Define the Custom session classes
```dbn-psql
  case class Transaction(sessionId: String, winAmount: Double, deposit: Boolean)

  case class SessionTrackingValue(totalSum: Double)

  case class SessionUpdate(sessionId: String, currentBalance: Double, depositCurrentBalance: Boolean)
```

  
### Create a local SparkSession running locally utilizing all cores

```dbn-psql
val spark: SparkSession = SparkSession
  .builder
  .master("local[*]")
  .appName(getClass.getName)
  .getOrCreate()
```

### Create a socket stream bound to port 9999 on localhost
```dbn-psql
val socketStream: DataFrame = spark.readStream
  // socket as stream input
  .format("socket")
  // connect to socket port localhost:9999 waiting for incoming stream
  .option("host", "localhost")
  .option("port", 9999)
  .load()
```

### Map the input to a Transaction case class

```dbn-psql
import spark.implicits._
    
    val transactions = socketStream
      .as[String]
      .map(inputLine => {
      val fields = inputLine.split(",")
      Transaction(fields(0), fields(1).toDouble, Try(fields(2).toBoolean).getOrElse(false))
    })
```

If the `deposit` field is contained in the input, it will be populated into the transaction.
If it is not contained in the input, we use `.getOrElse` to give it a value of `false`


### Create a KeyValueGroupedDataset of kv pairs (sessionId, Transaction)

    val idSessionKv: KeyValueGroupedDataset[String, Transaction] = transactions.groupByKey(x => x.sessionId)


### Use .mapGroupsWithState to check whether state exists and perform action on the state

```
    val sessionUpdates: Dataset[SessionUpdate] = idSessionKv.mapGroupsWithState[SessionTrackingValue, SessionUpdate](GroupStateTimeout.NoTimeout()) {
      // mapGroupsWithState: key: K, it: Iterator[V], s: GroupState[S]
      case (sessionId: String, eventsIter: Iterator[Transaction], state: GroupState[SessionTrackingValue]) => {
        val events = eventsIter.toSeq
        val updatedSession =
          if (state.exists) {
            val existingState = state.get
            val updatedEvents = SessionTrackingValue(existingState.totalSum + events.map(_.winAmount).sum)
            updatedEvents
          }
          else {
            SessionTrackingValue(events.map(event => event.winAmount).sum)
          }

        state.update(updatedSession)

        val toCloseSession = events.exists(_.deposit)

        // when there is an deposit in the event, close the session by removing the state
        if (toCloseSession) {
          // here we could perform a specific action when we receive the end of the session signal (store, send, update other state)
          // in this case we would just deposit the current balance to a data store
          // state.save() .. TODO unimplemented for this example
          state.remove()
          SessionUpdate(sessionId, updatedSession.totalSum, depositCurrentBalance = true)
        }
        else {
          SessionUpdate(sessionId, updatedSession.totalSum, depositCurrentBalance = false)
        }
      }
    }
```

TODO: explain

### Run the app

```dbn-psql
    val query: StreamingQuery = sessionUpdates
      .writeStream
      .outputMode("update")
      .format("console")
      .start()

    query.awaitTermination()
```

Full code [github-repo](https://github.com/joeyfaherty/streaming/blob/master/src/main/scala/structuredstreaming/SessionWindowUsingACustomState.scala)
