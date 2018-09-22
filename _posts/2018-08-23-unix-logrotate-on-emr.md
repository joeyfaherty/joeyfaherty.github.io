---
layout: post
title: Unix - Using LogRotate to keep an log storage to a minimum
comments: true
---

[Unix command logrotate](https://linux.die.net/man/8/logrotate), "rotates, compresses, and mails system logs"


When creating an EMR cluster for a streaming application, it is set up with a specific size storage and sometimes the amount of logs generated from the application can push the limits of the storage,
causing the application to crash.
Logrotate can help here by rotating and then later moving the logs to an external system (S3 or similar)


* Add this to the unix file: _**/etc/logrotate.conf**_

```
/path/to/application/app.log {
         copytruncate
         size 250M
         dateext
         rotate 8
         compress
         maxage 7
}
```

The above configuration will:

* rotate app logs when it reaches 250MB
* apply the **current date** as an extension
* keep **8** rotations
* compress to **tar.gz** file
* delete log files more than **7** days old