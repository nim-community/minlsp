discard """
  exitcode: 0
"""

import std/[os, strutils, options]
import minlsp/ntagger
import minlsp/logger
import compiler/[options, idents]

# Suppress log output during tests
quietMode = true

const testdataDir = currentSourcePath.parentDir.parentDir / "testdata"

# Test helper for temporary files (kept only for edge cases)
proc createTempTestFile(content: string): string =
  let testDir = getTempDir() / "minlsp_ntagger_test"
  createDir(testDir)
  let testFile = testDir / "test.nim"
  writeFile(testFile, content)
  return testFile

proc cleanupTempFiles() =
  let testDir = getTempDir() / "minlsp_ntagger_test"
  if dirExists(testDir):
    removeDir(testDir)

# TagKind Tests

block tag_kind_names:
  doAssert tagKindName(tkType) == "type"
  doAssert tagKindName(tkVar) == "var"
  doAssert tagKindName(tkLet) == "let"
  doAssert tagKindName(tkConst) == "const"
  doAssert tagKindName(tkProc) == "proc"
  doAssert tagKindName(tkFunc) == "func"
  doAssert tagKindName(tkMethod) == "method"
  doAssert tagKindName(tkIterator) == "iterator"
  doAssert tagKindName(tkConverter) == "converter"
  doAssert tagKindName(tkMacro) == "macro"
  doAssert tagKindName(tkTemplate) == "template"
  doAssert tagKindName(tkModule) == "module"

# Tag Collection Tests (use sample projects)

block collect_tags_from_simple_proc:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  doAssert tags.len > 0
  
  var foundGreet = false
  var foundAdd = false
  for tag in tags:
    if tag.name == "greet":
      foundGreet = true
      doAssert tag.kind == tkProc
      doAssert tag.file == testFile
    if tag.name == "add":
      foundAdd = true
      doAssert tag.kind == tkProc
  
  doAssert foundGreet
  doAssert foundAdd

block collect_tags_from_type_section:
  let testFile = testdataDir / "multi_module" / "src" / "models.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundUser = false
  var foundPost = false
  for tag in tags:
    if tag.name == "User":
      foundUser = true
      doAssert tag.kind == tkType
    if tag.name == "Post":
      foundPost = true
      doAssert tag.kind == tkType
  
  doAssert foundUser
  doAssert foundPost

# Use language_constructs project for var/let/const and other constructs

block collect_tags_from_var_let_const_sections:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundVar = false
  var foundLet = false
  var foundConst = false
  
  for tag in tags:
    case tag.name
    of "globalVar":
      foundVar = true
      doAssert tag.kind == tkVar
    of "constantValue":
      foundLet = true
      doAssert tag.kind == tkLet
    of "MAX_SIZE":
      foundConst = true
      doAssert tag.kind == tkConst
    else:
      discard
  
  doAssert foundVar
  doAssert foundLet
  doAssert foundConst

block collect_tags_from_func:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundFunc = false
  for tag in tags:
    if tag.name == "add":
      foundFunc = true
      doAssert tag.kind == tkFunc
      break
  
  doAssert foundFunc

block collect_tags_from_method:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundMethod = false
  for tag in tags:
    if tag.name == "speak":
      foundMethod = true
      doAssert tag.kind == tkMethod
      break
  
  doAssert foundMethod

block collect_tags_from_macro:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundMacro = false
  for tag in tags:
    if tag.name == "identity":
      foundMacro = true
      doAssert tag.kind == tkMacro
      break
  
  doAssert foundMacro

block collect_tags_from_template:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundTemplate = false
  for tag in tags:
    if tag.name == "debugPrint":
      foundTemplate = true
      doAssert tag.kind == tkTemplate
      break
  
  doAssert foundTemplate

block collect_tags_from_iterator:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundIterator = false
  for tag in tags:
    if tag.name == "countTo":
      foundIterator = true
      doAssert tag.kind == tkIterator
      break
  
  doAssert foundIterator

block collect_tags_from_converter:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundConverter = false
  for tag in tags:
    if tag.name == "toString":
      foundConverter = true
      doAssert tag.kind == tkConverter
      break
  
  doAssert foundConverter

block collect_tags_from_generic_containers:
  let testFile = testdataDir / "generic_types" / "src" / "containers.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundNewBox = false
  var foundGetValue = false
  
  for tag in tags:
    if tag.name == "newBox":
      foundNewBox = true
      doAssert tag.kind == tkProc
    if tag.name == "getValue":
      foundGetValue = true
      doAssert tag.kind == tkProc
  
  doAssert foundNewBox
  doAssert foundGetValue

block procedure_signatures_are_captured:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundSignature = false
  for tag in tags:
    if tag.name == "greet":
      foundSignature = true
      doAssert tag.signature.contains("name")
      break
  
  doAssert foundSignature

block generic_procedure_signatures:
  let testFile = testdataDir / "generic_types" / "src" / "containers.nim"
  
  var conf = newConfigRef()
  var cache = newIdentCache()
  let tags = collectTagsForFile(conf, cache, testFile, includePrivate = true)
  
  var foundSignature = false
  for tag in tags:
    if tag.name == "newBox":
      foundSignature = true
      doAssert tag.signature.contains("T")
      break
  
  doAssert foundSignature

# Directory Scanning Tests (use sample projects)

block generate_ctags_for_directory:
  let testDir = testdataDir / "simple_project" / "src"
  
  let tags = generateCtagsForDir([testDir], excludes = [], includePrivate = true)
  
  doAssert tags.len >= 4  # At least utils.nim + main.nim symbols
  
  var foundGreet = false
  var foundPerson = false
  for tag in tags:
    if tag.name == "greet":
      foundGreet = true
    if tag.name == "Person":
      foundPerson = true
  
  doAssert foundGreet
  doAssert foundPerson

block generate_ctags_for_multi_module_project:
  let testDir = testdataDir / "multi_module" / "src"
  
  let tags = generateCtagsForDir([testDir], excludes = [], includePrivate = true)
  
  var foundUser = false
  var foundGetUserById = false
  for tag in tags:
    if tag.name == "User":
      foundUser = true
    if tag.name == "getUserById":
      foundGetUserById = true
  
  doAssert foundUser
  doAssert foundGetUserById

block generate_ctags_for_language_constructs:
  let testDir = testdataDir / "language_constructs" / "src"
  
  let tags = generateCtagsForDir([testDir], excludes = [], includePrivate = true)
  
  var foundFunc = false
  var foundMacro = false
  var foundTemplate = false
  var foundIterator = false
  var foundConverter = false
  
  for tag in tags:
    case tag.name
    of "add": foundFunc = true
    of "identity": foundMacro = true
    of "debugPrint": foundTemplate = true
    of "countTo": foundIterator = true
    of "toString": foundConverter = true
    else: discard
  
  doAssert foundFunc
  doAssert foundMacro
  doAssert foundTemplate
  doAssert foundIterator
  doAssert foundConverter

block exclude_patterns_work:
  let testDir = testdataDir / "multi_module" / "src"
  
  # Exclude "models" - should not find User/Post types
  let tags = generateCtagsForDir([testDir], excludes = ["models"], includePrivate = true)
  
  var foundUser = false
  var foundGetUserById = false
  for tag in tags:
    if tag.name == "User":
      foundUser = true
    if tag.name == "getUserById":
      foundGetUserById = true
  
  # User should be excluded but getUserById from services should be present
  doAssert not foundUser
  doAssert foundGetUserById

block module_tags_are_generated:
  let testDir = testdataDir / "simple_project" / "src"
  
  let tags = generateCtagsForDir([testDir], excludes = [], modulesOnly = true)
  
  var foundUtilsModule = false
  var foundMainModule = false
  for tag in tags:
    if tag.name == "utils":
      foundUtilsModule = true
      doAssert tag.kind == tkModule
    if tag.name == "main":
      foundMainModule = true
      doAssert tag.kind == tkModule
  
  doAssert foundUtilsModule
  doAssert foundMainModule

# Tag Serialization Tests

block tag_to_string_conversion:
  let tags = @[
    Tag(name: "test", file: "/test.nim", line: 1, kind: tkProc, signature: ""),
    Tag(name: "other", file: "/test.nim", line: 5, kind: tkVar, signature: "")
  ]
  
  let output = $tags
  
  doAssert output.contains("!_TAG_FILE_FORMAT")
  doAssert output.contains("!_TAG_FILE_SORTED")
  doAssert output.contains("test")
  doAssert output.contains("other")
  doAssert output.contains("kind:proc")
  doAssert output.contains("kind:var")

block tag_output_contains_file_path:
  let tags = @[Tag(name: "myproc", file: "/home/user/test.nim", line: 10, kind: tkProc, signature: "")]
  let output = $tags
  doAssert output.contains("/home/user/test.nim")

block tag_output_contains_line_number:
  let tags = @[Tag(name: "myproc", file: "/test.nim", line: 42, kind: tkProc, signature: "")]
  let output = $tags
  doAssert output.contains("line:42")

block tag_output_sanitizes_newlines_in_signature:
  let tags = @[Tag(name: "myproc", file: "/test.nim", line: 1, kind: tkProc, signature: "line1\nline2")]
  let output = $tags
  # Newlines should be replaced with spaces
  doAssert not output.contains("\nline2")

# Tests pass silently
