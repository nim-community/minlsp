## Simple utility module for testing

proc greet*(name: string): string =
  ## Returns a greeting message
  "Hello, " & name & "!"

proc add*(a, b: int): int =
  ## Adds two integers
  a + b

type
  Person* = object
    name: string
    age: int

proc initPerson*(name: string, age: int): Person =
  Person(name: name, age: age)
