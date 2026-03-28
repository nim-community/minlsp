## Comprehensive Nim language constructs for testing

# Variables, constants, let bindings
var globalVar* = "test"
let constantValue* = 42
const MAX_SIZE* = 100

# Regular procedure
proc greet*(name: string): string =
  ## Returns a greeting message
  "Hello, " & name & "!"

# Function (pure)
func add*(a, b: int): int =
  ## Pure function that adds two numbers
  a + b

# Iterator
iterator countTo*(n: int): int =
  ## Yields numbers from 1 to n
  for i in 1..n:
    yield i

# Template
template debugPrint*(msg: string) =
  ## Debug output template
  echo "[DEBUG] ", msg

# Macro
macro identity*(x: untyped): untyped =
  ## Returns the input unchanged
  x

# Type definition
type
  Person* = object
    name*: string
    age*: int
  
  Status* = enum
    Active
    Inactive
    Pending

# Method (requires object type)
type Animal* = ref object of RootObj
  name*: string

method speak*(self: Animal) {.base.} =
  ## Base method for animals
  echo self.name, " makes a sound"

# Converter
converter toString*(x: int): string =
  ## Converts int to string
  $x
