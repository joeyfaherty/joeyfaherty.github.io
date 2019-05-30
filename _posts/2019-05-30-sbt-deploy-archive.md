---
layout: post
title: Package and Deploy an artifact using SBT
comments: true
---

> For full code go to [https://github.com/joeyfaherty/sbt-deployer]()

#### Problem:
- In a multi-module project, I want to be able to publish to artifactory a fat jar of my application, runner scripts and database scripts.

#### Solution:
- Using sbt's native-packager, release & assembly plugins when I will run `sbt "release with-defaults"`, 
it should perform all necessary steps to publish the archive artifact.


----

#### Steps:

This example uses sbt version `1.2.8`

1. Add the following plugins to `plugins.sbt`

    ```scala
    addSbtPlugin("com.typesafe.sbt" % "sbt-native-packager" % "1.3.21")
    addSbtPlugin("com.github.gseitz" % "sbt-release" % "1.0.11")
    addSbtPlugin("com.eed3si9n" % "sbt-assembly" % "0.14.9")
    ```

2. Define your repository to publish to. (In this case I use a local dummy repo as I dont have an artifactory set up. `build.sbt`
)

    ```scala
    publishTo := Some(Resolver.file("file", new File("/tmp/my/artifactory")))
    ```

3. Simple multi-module set up with a root project and 3 subprojects. `build.sbt`

    ```scala
    lazy val root = Project(
      id = "root",
      base = file("."),
    ) dependsOn(apiApp, service, common) // this does the actual aggregation
    
    // --------- Project Api ------------------
    lazy val apiApp = Project(
      id = "api-app",
      base = file("api-app")
    )
      .settings(commonSettings: _*)
      .dependsOn (common)
    
    
    // --------- Project Service ----------------
    lazy val service = Project(
      id = "service",
      base = file("service")
    ).dependsOn (common)
    
    
    // --------- Project Common ------------------
    lazy val common = Project(
      id = "common",
      base = file("common")
    )
    ```

4. Any resources in `src/universal` will get picked up by the command `universal:packageBin` and will be added to the archive.
I have added a `ddl.sql` file in `src/universal/ddl` and a `runner.sh` script in `src/universal/runner`

    ```bash
    ls -R src/universal/
    ddl	runner
    
    src/universal//ddl:
    ddl.sql
    
    src/universal//runner:
    runner.sh
    ```

5. Where the fat jar packaging magic happens. `build.sbt`
    ```scala
    import com.typesafe.sbt.SbtNativePackager._
    
    mappings in Universal := {
    
      val universalMappings = (mappings in Universal).value
      val fatJar = (assembly in Compile).value
    
      // we filter out any lib dependencies as in this case we only want the fat jar in the archive.
      val filtered = universalMappings filter {
        case (file, name) => !name.endsWith(".jar")
      }
    
      // now add the fat jar
      filtered :+ (fatJar -> ("lib/" + fatJar.getName))
    }
    ```

6. Add these release steps to `release.sbt`. These steps will then be executed when we run: `$ sbt "release with-defaults"`

    ```scala
    import sbtrelease.ReleasePlugin.autoImport.ReleaseTransformations._
    
    // enables the archive to be packaged
    enablePlugins(UniversalDeployPlugin)
    
    // these release steps are executed in sequence when the below command is run:
    // sbt "release with-defaults"
    releaseProcess := {
      Seq[ReleaseStep](
        // clean target directories 
        releaseStepCommand("clean"),
        // creates a zip file package in target/universal
        releaseStepCommand("universal:packageBin"),
        // creates the fat jar
        releaseStepCommand("universal:assembly"),
        // publishes this zip file to artifactory
        releaseStepCommand("universal:publish"),
        // generic publish which publishes the root app jar, javadoc, sources and pom.xml
        //publishArtifacts
      )
    }
    ```

---

#### Results
Running `$sbt clean "release with-defaults"` gives me the following output:

```bash
Running with tar -pcvf /var/folders/gt/5c1w4t512n15y6vcq766kttm0000gn/T/sbt_165ffa18/sbt-magic-joey-0.1.tar sbt-magic-joey-0.1
a sbt-magic-joey-0.1
a sbt-magic-joey-0.1/runner
a sbt-magic-joey-0.1/ddl
a sbt-magic-joey-0.1/lib
a sbt-magic-joey-0.1/lib/sbt-magic-joey-assembly-0.1.jar
a sbt-magic-joey-0.1/ddl/ddl.sql
a sbt-magic-joey-0.1/runner/runner.sh
.
.
.
[info] 	published sbt-magic-joey to /tmp/my/artifactory/my/home/sbt-magic-joey/0.1/sbt-magic-joey-0.1.tgz
[success] Total time: 1 s, completed 30-May-2019 09:15:57
```

#### Verify
And now to unzip the "published" archive to verify its contents are as we expect:
```bash
joey@macbook:sbt-deploy $unzip  /tmp/my/artifactory/my/home/sbt-magic-joey/0.1/sbt-magic-joey-0.1.zip
Archive:  /tmp/my/artifactory/my/home/sbt-magic-joey/0.1/sbt-magic-joey-0.1.zip
  inflating: sbt-magic-joey-0.1/runner/runner.sh  
  inflating: sbt-magic-joey-0.1/ddl/ddl.sql  
  inflating: sbt-magic-joey-0.1/lib/sbt-magic-joey-assembly-0.1.jar
```

 




