import std/[os, options, tables]
import minlsp
import minlsp/baseprotocol

proc myExtractWord(content: string, line, character: int): string =
  var currLine = 0
  var i = 0
  let n = content.len
  while i < n and currLine < line:
    if content[i] == '\n':
      inc(currLine)
    inc(i)
  var start = i
  while i < n and content[i] != '\n':
    inc(i)
  let currentLine = content[start ..< i]
  if character >= currentLine.len:
    return ""
  var s = character
  var e = character
  while s > 0 and currentLine[s-1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    dec(s)
  while e < currentLine.len and currentLine[e] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    inc(e)
  if s >= e: return ""
  return currentLine[s..<e]

let testDir = getTempDir() / "minlsp_repro_def"
createDir(testDir)
let testFile = testDir / "test.nim"
writeFile(testFile, """proc foo(x: int): int =
  x + 1

proc foo(x: string): string =
  x & "!"

proc bar(): int =
  foo(1)

proc baz(): string =
  foo("hello")
""")

let lsp = initMinLSP()
let content = readFile(testFile)
lsp.updateFile("file://" & testFile, content, immediate = true)

# Correct lines:
# line 0: proc foo(x: int): int =
# line 1:   x + 1
# line 2: (empty)
# line 3: proc foo(x: string): string =
# line 4:   x & "!"
# line 5: (empty)
# line 6: proc bar(): int =
# line 7:   foo(1)
# line 8: (empty)
# line 9: proc baz(): string =
# line 10:  foo("hello")

echo "word at (0,6): '", myExtractWord(content, 0, 6), "'"
echo "word at (3,6): '", myExtractWord(content, 3, 6), "'"
echo "word at (7,2): '", myExtractWord(content, 7, 2), "'"
echo "word at (10,2): '", myExtractWord(content, 10, 2), "'"

let d0 = lsp.findDefinition("file://" & testFile, 0, 6)
let d3 = lsp.findDefinition("file://" & testFile, 3, 6)
let d7 = lsp.findDefinition("file://" & testFile, 7, 2)
let d10 = lsp.findDefinition("file://" & testFile, 10, 2)

proc fmtDef(defs: seq[Location]): string =
  if defs.len == 0: return "NONE"
  if defs.len == 1: return $defs[0].range.startPos.line
  result = "[" & $defs[0].range.startPos.line
  for i in 1 ..< defs.len:
    result.add(", " & $defs[i].range.startPos.line)
  result.add("]")

echo "findDefinition(0,6)=", fmtDef(d0)
echo "findDefinition(3,6)=", fmtDef(d3)
echo "findDefinition(7,2)=", fmtDef(d7)
echo "findDefinition(10,2)=", fmtDef(d10)

# Assertions:
doAssert d0.len == 1 and d0[0].range.startPos.line == 0, "definition on line 0 should return itself"
doAssert d3.len == 1 and d3[0].range.startPos.line == 3, "definition on line 3 should return itself"
doAssert d7.len == 2, "call site should return both overloads"
doAssert d10.len == 2, "call site should return both overloads"
echo "All assertions passed!"
