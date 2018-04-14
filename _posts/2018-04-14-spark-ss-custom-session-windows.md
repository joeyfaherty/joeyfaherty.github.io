---
layout: post
title: Spark Structured Streaming - Custom Session Windows
---

[Spark Structured Streaming](https://spark.apache.org/docs/latest/structured-streaming-programming-guide.html) allows us to perform aggregations over a sliding event-time window in a straightword manner out of the box using  [windowing operation on event time](https://spark.apache.org/docs/latest/structured-streaming-programming-guide.html#window-operations-on-event-time) and [watermarking](https://spark.apache.org/docs/latest/structured-streaming-programming-guide.html#handling-late-data-and-watermarking).  But, what if you do not want to base your session on a time-based window, but instead on a custom session window.  

> For example you stream transactions and these consist of two types: 

