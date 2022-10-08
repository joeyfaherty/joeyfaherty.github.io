---
layout: post
title: Spark SQL - take your output column names directly from your case classes
comments: true
---

#### Background
Avoid duplication and/or hardcoding of a list of columns that you will use 
for your output datasets.  Once you have your domain correctly modelled, 
you can use this function to extract the attribute names from your case class.


#### Example Domain (case classes)

```

  case class Food(
                  fat: Int,
                  protein: Int,
                  carbohydrates: Int,
                  vitamins: List[String],
                  minerals: Liist[String]
                  )
      
```

#### Function

```

  def extractCaseClassAttribuesAsColumnsList[T](c: Class[T]): Seq[Column] = {
    c
      .getDeclaredFields
      .map(f => col(f.getName))
      .toSeq
      
```

#### Calling The Function

```

  val outputColumns: Seq[Columns] = extractCaseClassAttribuesAsColumnsList[Food]
   
  dataset
    .select(outputColumns: _*)   
    
```