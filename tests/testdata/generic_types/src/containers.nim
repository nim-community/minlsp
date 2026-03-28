## Generic container types for testing generic proc signatures

type
  Box*[T] = object
    value: T

  Result*[T, E] = object
    case ok*: bool
    of true:
      value*: T
    of false:
      error*: E

proc newBox*[T](value: T): Box[T] =
  Box[T](value: value)

proc getValue*[T](box: Box[T]): T =
  box.value

proc okResult*[T, E](value: T): Result[T, E] =
  Result[T, E](ok: true, value: value)

proc errResult*[T, E](error: E): Result[T, E] =
  Result[T, E](ok: false, error: error)
