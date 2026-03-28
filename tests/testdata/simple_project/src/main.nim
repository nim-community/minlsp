## Main module that imports utils
import utils

proc main() =
  let person = initPerson("Nim", 10)
  echo greet(person.name)
  echo "Age: ", add(person.age, 5)

when isMainModule:
  main()
