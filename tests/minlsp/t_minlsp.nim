discard """
  exitcode: 0
"""

import std/[os, strutils, tables, options]
import minlsp
import minlsp/ntagger
import minlsp/logger

# Suppress log output during tests
quietMode = true

const testdataDir = currentSourcePath.parentDir.parentDir / "testdata"

# Test helper for temporary files (for tests that need them)
proc createTempTestFile(content: string): string =
  let testDir = getTempDir() / "minlsp_test"
  createDir(testDir)
  let testFile = testDir / "test.nim"
  writeFile(testFile, content)
  return testFile

proc cleanupTempFiles() =
  let testDir = getTempDir() / "minlsp_test"
  if dirExists(testDir):
    removeDir(testDir)

# MinLSP Initialization Tests

block initialize_minlsp:
  let lsp = initMinLSP()
  doAssert lsp.rootPath == ""
  doAssert lsp.initialized == false
  doAssert lsp.shutdownRequested == false
  doAssert lsp.ctagsCache.len == 0
  doAssert lsp.openFiles.len == 0

# MinLSP File Operations Tests (use temp files)

block update_file_adds_to_open_files:
  let lsp = initMinLSP()
  let testFile = createTempTestFile("proc test() = discard")
  let uri = "file://" & testFile
  
  lsp.updateFile(uri, "proc test() = discard")
  doAssert lsp.openFiles.hasKey(testFile)
  doAssert lsp.openFiles[testFile] == "proc test() = discard"

cleanupTempFiles()

block remove_file_deletes_from_open_files_and_cache:
  let lsp = initMinLSP()
  let testFile = createTempTestFile("proc test() = discard")
  let uri = "file://" & testFile
  
  lsp.updateFile(uri, "proc test() = discard")
  doAssert lsp.openFiles.hasKey(testFile)
  
  lsp.removeFile(uri)
  doAssert not lsp.openFiles.hasKey(testFile)
  doAssert not lsp.ctagsCache.hasKey(testFile)

cleanupTempFiles()

# MinLSP Tag Generation Tests (use sample projects)

block generate_ctags_for_simple_nim_file:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let lsp = initMinLSP()
  let tags = lsp.generateCtagsForFile(testFile)
  
  doAssert tags.len > 0
  
  var foundGreet = false
  var foundPerson = false
  var foundAdd = false
  
  for tag in tags:
    case tag.name
    of "greet":
      foundGreet = true
      doAssert tag.kind == tkProc
    of "Person":
      foundPerson = true
      doAssert tag.kind == tkType
    of "add":
      foundAdd = true
      doAssert tag.kind == tkProc
    else:
      discard
  
  doAssert foundGreet
  doAssert foundPerson
  doAssert foundAdd

block generate_ctags_for_multi_module:
  let modelsFile = testdataDir / "multi_module" / "src" / "models.nim"
  let servicesFile = testdataDir / "multi_module" / "src" / "services.nim"
  let lsp = initMinLSP()
  
  let modelsTags = lsp.generateCtagsForFile(modelsFile)
  let servicesTags = lsp.generateCtagsForFile(servicesFile)
  
  # Check models
  var foundUser = false
  var foundPost = false
  for tag in modelsTags:
    if tag.name == "User":
      foundUser = true
      doAssert tag.kind == tkType
    if tag.name == "Post":
      foundPost = true
      doAssert tag.kind == tkType
  
  doAssert foundUser
  doAssert foundPost
  
  # Check services
  var foundGetUserById = false
  for tag in servicesTags:
    if tag.name == "getUserById":
      foundGetUserById = true
      doAssert tag.kind == tkProc
  
  doAssert foundGetUserById

block ctags_are_cached:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let lsp = initMinLSP()
  
  # First call should populate cache
  discard lsp.generateCtagsForFile(testFile)
  doAssert lsp.ctagsCache.hasKey(testFile)
  
  # Second call should use cached value
  let cachedTags = lsp.generateCtagsForFile(testFile)
  doAssert lsp.ctagsCache[testFile].len == cachedTags.len

block generate_ctags_for_generic_types:
  let testFile = testdataDir / "generic_types" / "src" / "containers.nim"
  let lsp = initMinLSP()
  let tags = lsp.generateCtagsForFile(testFile)
  
  var foundNewBox = false
  var foundGetValue = false
  var foundOkResult = false
  
  for tag in tags:
    case tag.name
    of "newBox":
      foundNewBox = true
      doAssert tag.kind == tkProc
    of "getValue":
      foundGetValue = true
      doAssert tag.kind == tkProc
    of "okResult":
      foundOkResult = true
      doAssert tag.kind == tkProc
    else: discard
  
  doAssert foundNewBox
  doAssert foundGetValue
  doAssert foundOkResult

# MinLSP Completion Tests (use sample projects)

block get_completions_returns_symbols:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  
  let completions = lsp.getCompletions("file://" & testFile, 0, 0)
  
  doAssert completions.len > 0
  
  var foundGreet = false
  var foundPerson = false
  
  for completion in completions:
    case completion.label
    of "greet":
      foundGreet = true
      doAssert completion.kind == CompletionItemKind.Function
    of "Person":
      foundPerson = true
      doAssert completion.kind == CompletionItemKind.Class
    else:
      discard
  
  doAssert foundGreet
  doAssert foundPerson

block completions_include_signatures:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  
  let completions = lsp.getCompletions("file://" & testFile, 0, 0)
  
  var foundGreet = false
  for completion in completions:
    if completion.label == "greet":
      foundGreet = true
      doAssert completion.detail.contains("name")
      break
  
  doAssert foundGreet

block completions_from_multi_module:
  let testFile = testdataDir / "multi_module" / "src" / "services.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  
  let completions = lsp.getCompletions("file://" & testFile, 0, 0)
  
  var foundGetUserById = false
  for completion in completions:
    if completion.label == "getUserById":
      foundGetUserById = true
      break
  
  doAssert foundGetUserById

# MinLSP Definition Tests (use sample projects)

block find_definition_returns_location:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)
  
  # Try to find definition of "greet" proc (line 2: "proc greet*(name: string): string =")
  # Looking for "greet" at column 6 (0-indexed: after "proc ")
  let defLocation = lsp.findDefinition("file://" & testFile, 2, 6)

  doAssert defLocation.len > 0
  let loc = defLocation[0]
  doAssert loc.uri == "file://" & testFile

cleanupTempFiles()

block find_definition_returns_none_for_unknown_word:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  lsp.updateFile("file://" & testFile, content)
  
  # Looking for a word that doesn't exist
  let defLocation = lsp.findDefinition("file://" & testFile, 0, 500)
  doAssert defLocation.len == 0

block find_definition_returns_none_for_out_of_bounds_line:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  lsp.updateFile("file://" & testFile, content)
  
  let defLocation = lsp.findDefinition("file://" & testFile, 1000, 0)
  doAssert defLocation.len == 0

# MinLSP Hover Tests (use sample projects)

block get_hover_returns_hover_info:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)
  
  # Try to get hover for "greet" at the definition line
  let hoverOpt = lsp.getHover("file://" & testFile, 2, 6)
  
  doAssert hoverOpt.isSome
  let hover = hoverOpt.get()
  doAssert hover.contents.value.contains("greet")

block get_hover_returns_none_for_unknown_word:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  lsp.updateFile("file://" & testFile, content)
  
  # Looking for hover on non-existent word
  let hoverOpt = lsp.getHover("file://" & testFile, 0, 500)
  doAssert not hoverOpt.isSome

block get_hover_returns_exact_definition_on_definition_line:
  let testFile = createTempTestFile("proc foo(x: int): int =\n  x + 1\n\nproc foo(x: string): string =\n  x & \"!\"\n")
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  let content = readFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  let hover1 = lsp.getHover("file://" & testFile, 0, 6)
  doAssert hover1.isSome
  doAssert hover1.get().contents.value.contains("foo(x: int): int")
  doAssert not hover1.get().contents.value.contains("foo(x: string): string")

  let hover2 = lsp.getHover("file://" & testFile, 3, 6)
  doAssert hover2.isSome
  doAssert hover2.get().contents.value.contains("foo(x: string): string")
  doAssert not hover2.get().contents.value.contains("foo(x: int): int")

cleanupTempFiles()

block get_hover_returns_all_overloads_at_call_site:
  let testFile = createTempTestFile("proc foo(x: int): int =\n  x + 1\n\nproc foo(x: string): string =\n  x & \"!\"\n\nproc bar(): int =\n  foo(1)\n")
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  let content = readFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  let hover = lsp.getHover("file://" & testFile, 7, 2)
  doAssert hover.isSome
  doAssert hover.get().contents.value.contains("foo(x: int): int")
  doAssert hover.get().contents.value.contains("foo(x: string): string")

cleanupTempFiles()

block find_definition_returns_exact_definition_on_definition_line:
  let testFile = createTempTestFile("proc foo(x: int): int =\n  x + 1\n\nproc foo(x: string): string =\n  x & \"!\"\n")
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  let content = readFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  let def1 = lsp.findDefinition("file://" & testFile, 0, 6)
  doAssert def1.len == 1
  doAssert def1[0].range.startPos.line == 0

  let def2 = lsp.findDefinition("file://" & testFile, 3, 6)
  doAssert def2.len == 1
  doAssert def2[0].range.startPos.line == 3

cleanupTempFiles()

# MinLSP Document Symbol Tests (use sample projects)

block get_document_symbols_returns_symbols:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  
  let symbols = lsp.getDocumentSymbols("file://" & testFile)
  
  doAssert symbols.len >= 3
  
  var foundGreet = false
  var foundAdd = false
  var foundPerson = false
  
  for symbol in symbols:
    case symbol.name
    of "greet":
      foundGreet = true
      doAssert symbol.kind == SymbolKind.Function
    of "add":
      foundAdd = true
      doAssert symbol.kind == SymbolKind.Function
    of "Person":
      foundPerson = true
      doAssert symbol.kind == SymbolKind.Class
    else:
      discard
  
  doAssert foundGreet
  doAssert foundAdd
  doAssert foundPerson

block get_document_symbols_from_models:
  let testFile = testdataDir / "multi_module" / "src" / "models.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  
  let symbols = lsp.getDocumentSymbols("file://" & testFile)
  
  var foundUser = false
  var foundPost = false
  
  for symbol in symbols:
    if symbol.name == "User":
      foundUser = true
      doAssert symbol.kind == SymbolKind.Class
    if symbol.name == "Post":
      foundPost = true
      doAssert symbol.kind == SymbolKind.Class
  
  doAssert foundUser
  doAssert foundPost

# MinLSP Position and Range Tests

block position_object_creation:
  let pos = Position(line: 10, character: 5)
  doAssert pos.line == 10
  doAssert pos.character == 5

block range_object_creation:
  let range = Range(
    startPos: Position(line: 0, character: 0),
    endPos: Position(line: 10, character: 5)
  )
  doAssert range.startPos.line == 0
  doAssert range.endPos.line == 10

block location_object_creation:
  let loc = Location(
    uri: "file:///test.nim",
    range: Range(
      startPos: Position(line: 0, character: 0),
      endPos: Position(line: 1, character: 0)
    )
  )
  doAssert loc.uri == "file:///test.nim"
  doAssert loc.range.startPos.line == 0

# Object field and enum member tests

block get_hover_returns_hover_info_for_object_field:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  # Hover on "name" field at line 12, col 4
  let hoverOpt = lsp.getHover("file://" & testFile, 12, 4)
  doAssert hoverOpt.isSome
  let hover = hoverOpt.get()
  doAssert hover.contents.value.contains("name")

block get_hover_returns_hover_info_for_enum_member:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  # Hover on "Active" enum member at line 40, col 4
  let hoverOpt = lsp.getHover("file://" & testFile, 40, 4)
  doAssert hoverOpt.isSome
  let hover = hoverOpt.get()
  doAssert hover.contents.value.contains("Active")

block find_definition_returns_location_for_object_field:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  let defLocation = lsp.findDefinition("file://" & testFile, 12, 4)
  doAssert defLocation.len > 0
  let loc = defLocation[0]
  doAssert loc.uri == "file://" & testFile

block find_definition_returns_location_for_enum_member:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  let defLocation = lsp.findDefinition("file://" & testFile, 40, 4)
  doAssert defLocation.len > 0
  let loc = defLocation[0]
  doAssert loc.uri == "file://" & testFile

# New LSP capability tests

block get_signature_help_returns_signature_info:
  let testFile = testdataDir / "simple_project" / "src" / "main.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  let utilsFile = testdataDir / "simple_project" / "src" / "utils.nim"
  discard lsp.generateCtagsForFile(utilsFile)
  lsp.updateFile("file://" & testFile, content)

  # Signature help on "greet(" at line 5, col 12 (the opening paren)
  let sigOpt = lsp.getSignatureHelp("file://" & testFile, 5, 12)
  doAssert sigOpt.isSome
  let sig = sigOpt.get()
  doAssert sig.signatures.len > 0
  doAssert sig.signatures[0].label.contains("greet")

block get_signature_help_returns_all_overloads:
  let testFile = createTempTestFile("proc foo(x: int): int =\n  x + 1\n\nproc foo(x: string): string =\n  x & \"!\"\n\nproc bar(): int =\n  foo(1)\n")
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  let content = readFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  # Signature help inside foo(1) call at line 7, col 6 (the opening paren)
  let sigOpt = lsp.getSignatureHelp("file://" & testFile, 7, 6)
  doAssert sigOpt.isSome
  let sig = sigOpt.get()
  doAssert sig.signatures.len == 2
  var foundInt = false
  var foundString = false
  for s in sig.signatures:
    if s.label.contains("int"): foundInt = true
    if s.label.contains("string"): foundString = true
  doAssert foundInt
  doAssert foundString

cleanupTempFiles()

block get_references_returns_locations:
  let testFile = testdataDir / "simple_project" / "src" / "main.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  let utilsFile = testdataDir / "simple_project" / "src" / "utils.nim"
  discard lsp.generateCtagsForFile(utilsFile)
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  # References for "greet" proc at line 5, col 8 in main.nim
  let refs = lsp.getReferences("file://" & testFile, 5, 8, true)
  doAssert refs.len >= 2
  var foundMain = false
  var foundUtils = false
  for r in refs:
    if r.uri == "file://" & testFile:
      foundMain = true
    if r.uri == "file://" & utilsFile:
      foundUtils = true
  doAssert foundMain
  doAssert foundUtils

block rename_symbol_returns_edits:
  let testFile = testdataDir / "simple_project" / "src" / "main.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  let utilsFile = testdataDir / "simple_project" / "src" / "utils.nim"
  discard lsp.generateCtagsForFile(utilsFile)
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  # Rename "greet" at line 5, col 8 in main.nim
  let edits = lsp.renameSymbol("file://" & testFile, 5, 8, "newGreet")
  doAssert edits.len >= 2
  var foundMain = false
  var foundUtils = false
  for e in edits:
    if e.uri == "file://" & testFile:
      foundMain = true
    if e.uri == "file://" & utilsFile:
      foundUtils = true
  doAssert foundMain
  doAssert foundUtils

block get_workspace_symbols_returns_matching_symbols:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)

  let symbols = lsp.getWorkspaceSymbols("greet")
  doAssert symbols.len > 0
  doAssert symbols[0].name == "greet"

block get_diagnostics_returns_empty_for_valid_file:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  lsp.updateFile("file://" & testFile, content)

  let diags = lsp.getDiagnostics("file://" & testFile)
  doAssert diags.len == 0

# Tests pass silently - only output on failure
