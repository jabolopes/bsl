me Test.TestData10

let f1 x@isInt = f2 x
where
  let f2 y =
    f3 y
  where
    let f3 w = w + x
