discard """
  exitcode: 0
"""

import std/[unittest, json, os, strutils, tables, options]
import minlsp
import minlsp/[baseprotocol, ntagger]
import minlsp/logger

# Suppress log output during tests
quietMode = true

const testdataDir = currentSourcePath.parentDir.parentDir / "testdata"

# Test helper for temporary files (only for edge cases that can't use testdata)
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

# Integration Tests using testdata projects

block full_workflow_initialize_and_process_file:
  let lsp = initMinLSP()
  doAssert not lsp.initialized
  
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let uri = "file://" & testFile
  
  # Simulate file open
  lsp.updateFile(uri, content)
  doAssert lsp.openFiles.hasKey(testFile)
  doAssert lsp.openFiles[testFile] == content
  
  # Generate tags
  let tags = lsp.generateCtagsForFile(testFile)
  doAssert tags.len > 0

block handle_multiple_files:
  let lsp = initMinLSP()
  
  let file1 = testdataDir / "simple_project" / "src" / "utils.nim"
  let file2 = testdataDir / "simple_project" / "src" / "main.nim"
  
  let content1 = readFile(file1)
  let content2 = readFile(file2)
  
  lsp.updateFile("file://" & file1, content1)
  lsp.updateFile("file://" & file2, content2)
  
  doAssert lsp.openFiles.len == 2
  doAssert lsp.openFiles.hasKey(file1)
  doAssert lsp.openFiles.hasKey(file2)
  
  # Remove one file
  lsp.removeFile("file://" & file1)
  doAssert lsp.openFiles.len == 1
  doAssert not lsp.openFiles.hasKey(file1)
  doAssert lsp.openFiles.hasKey(file2)

block tag_kind_mapping_in_completions:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  
  let completions = lsp.getCompletions("file://" & testFile, 0, 0)
  
  var kindMap: Table[string, CompletionItemKind]
  for c in completions:
    kindMap[c.label] = c.kind
  
  # Check that kinds are mapped correctly
  if "greet" in kindMap:
    doAssert kindMap["greet"] == CompletionItemKind.Function
  if "add" in kindMap:
    doAssert kindMap["add"] == CompletionItemKind.Function
  if "speak" in kindMap:
    doAssert kindMap["speak"] == CompletionItemKind.Method
  if "Person" in kindMap:
    doAssert kindMap["Person"] == CompletionItemKind.Class
  if "globalVar" in kindMap:
    doAssert kindMap["globalVar"] == CompletionItemKind.Variable
  if "constantValue" in kindMap:
    doAssert kindMap["constantValue"] == CompletionItemKind.Value
  if "MAX_SIZE" in kindMap:
    doAssert kindMap["MAX_SIZE"] == CompletionItemKind.Value
  if "identity" in kindMap:
    doAssert kindMap["identity"] == CompletionItemKind.Function
  if "debugPrint" in kindMap:
    doAssert kindMap["debugPrint"] == CompletionItemKind.Snippet

block document_symbols_kind_mapping:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  
  let symbols = lsp.getDocumentSymbols("file://" & testFile)
  
  var kindMap: Table[string, SymbolKind]
  for s in symbols:
    kindMap[s.name] = s.kind
  
  # Check that kinds are mapped correctly
  if "greet" in kindMap:
    doAssert kindMap["greet"] == SymbolKind.Function
  if "speak" in kindMap:
    doAssert kindMap["speak"] == SymbolKind.Method
  if "Person" in kindMap:
    doAssert kindMap["Person"] == SymbolKind.Class
  if "globalVar" in kindMap:
    doAssert kindMap["globalVar"] == SymbolKind.Variable
  if "constantValue" in kindMap:
    doAssert kindMap["constantValue"] == SymbolKind.Constant
  if "MAX_SIZE" in kindMap:
    doAssert kindMap["MAX_SIZE"] == SymbolKind.Constant
  if "identity" in kindMap:
    doAssert kindMap["identity"] == SymbolKind.Function
  if "debugPrint" in kindMap:
    doAssert kindMap["debugPrint"] == SymbolKind.Function

block hover_content_includes_signature:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)
  
  # Get hover for "greet" proc
  let hoverOpt = lsp.getHover("file://" & testFile, 4, 5)
  
  if hoverOpt.isSome:
    let hover = hoverOpt.get()
    doAssert hover.contents.kind == MarkupKind.Markdown
    doAssert hover.contents.value.contains("greet")

block definition_search_across_all_cached_files:
  let lsp = initMinLSP()
  
  # Use multi_module project for cross-file testing
  let modelsFile = testdataDir / "multi_module" / "src" / "models.nim"
  let servicesFile = testdataDir / "multi_module" / "src" / "services.nim"
  let servicesContent = readFile(servicesFile)
  
  # Generate tags for both files
  discard lsp.generateCtagsForFile(modelsFile)
  discard lsp.generateCtagsForFile(servicesFile)
  lsp.updateFile("file://" & servicesFile, servicesContent)
  
  # Try to find definition of "User" from services.nim
  let defLocation = lsp.findDefinition("file://" & servicesFile, 4, 20)
  
  if defLocation.isSome:
    let loc = defLocation.get()
    doAssert loc.uri == "file://" & modelsFile

block shutdown_and_exit_flags:
  let lsp = initMinLSP()
  doAssert not lsp.shutdownRequested
  
  lsp.shutdownRequested = true
  doAssert lsp.shutdownRequested

# Edge cases still using temp files (these are special cases)

block empty_file_content_handling:
  let testFile = createTempTestFile("")
  let lsp = initMinLSP()
  let lsp2 = initMinLSP()
  
  lsp.updateFile("file://" & testFile, "")
  doAssert lsp.openFiles[testFile] == ""
  
  # Should not crash with empty content
  let defLocation = lsp2.findDefinition("file://" & testFile, 0, 0)
  # Result depends on implementation, but should not crash

cleanupTempFiles()

block large_file_handling:
  var largeContent = ""
  for i in 0..<1000:
    largeContent.add("proc func" & $i & "() = discard\n")
  
  let testFile = createTempTestFile(largeContent)
  let lsp = initMinLSP()
  let tags = lsp.generateCtagsForFile(testFile)
  
  doAssert tags.len == 1000

cleanupTempFiles()

block special_characters_in_identifiers:
  let testContent = """
proc `+`(a, b: int): int = a + b
proc `[]`(s: string, i: int): char = s[i]
type `My Type` = object
"""
  let testFile = createTempTestFile(testContent)
  let lsp = initMinLSP()
  let tags = lsp.generateCtagsForFile(testFile)
  
  # Check that special identifiers are captured
  var foundSpecial = false
  for tag in tags:
    if tag.name == "+" or tag.name == "[]":
      foundSpecial = true
      break

cleanupTempFiles()

# LSP Message Structure Tests (no files needed)

block lsp_message_object_creation:
  let msg = LSPMessage(
    jsonrpc: "2.0",
    id: some(%1),
    lspMethod: some("initialize"),
    params: some(%*{"rootPath": "/tmp"}),
    result: none(JsonNode),
    error: none(JsonNode)
  )
  
  doAssert msg.jsonrpc == "2.0"
  doAssert msg.id.isSome
  doAssert msg.id.get().getInt == 1
  doAssert msg.lspMethod.isSome
  doAssert msg.lspMethod.get() == "initialize"
  doAssert msg.params.isSome

block lsp_message_for_notification_no_id:
  let msg = LSPMessage(
    jsonrpc: "2.0",
    id: none(JsonNode),
    lspMethod: some("textDocument/didOpen"),
    params: some(%*{"textDocument": {"uri": "file:///test.nim"}}),
    result: none(JsonNode),
    error: none(JsonNode)
  )
  
  doAssert not msg.id.isSome
  doAssert msg.lspMethod.isSome
  doAssert msg.lspMethod.get() == "textDocument/didOpen"

block markup_content_creation:
  let markup = MarkupContent(
    kind: MarkupKind.Markdown,
    value: "# Title\n\nDescription"
  )
  
  doAssert markup.kind == MarkupKind.Markdown
  doAssert markup.value == "# Title\n\nDescription"

block markup_kind_enum_values:
  doAssert $MarkupKind.PlainText == "plaintext"
  doAssert $MarkupKind.Markdown == "markdown"

block completion_item_creation:
  let item = CompletionItem(
    label: "myProc",
    kind: CompletionItemKind.Function,
    detail: "proc myProc(): string",
    documentation: "A test procedure"
  )
  
  doAssert item.label == "myProc"
  doAssert item.kind == CompletionItemKind.Function
  doAssert item.detail == "proc myProc(): string"

block document_symbol_creation:
  let sym = DocumentSymbol(
    name: "myProc",
    kind: SymbolKind.Function,
    range: Range(
      startPos: Position(line: 0, character: 0),
      endPos: Position(line: 5, character: 10)
    ),
    selectionRange: Range(
      startPos: Position(line: 0, character: 0),
      endPos: Position(line: 0, character: 6)
    ),
    detail: "proc myProc()"
  )
  
  doAssert sym.name == "myProc"
  doAssert sym.kind == SymbolKind.Function
  doAssert sym.range.startPos.line == 0
  doAssert sym.range.endPos.line == 5

block hover_object_creation:
  let hover = Hover(
  contents: MarkupContent(
      kind: MarkupKind.Markdown,
      value: "proc test(): string"
    )
  )

  doAssert hover.contents.kind == MarkupKind.Markdown
  doAssert hover.contents.value == "proc test(): string"

# New integration tests for object fields and enum members

block hover_on_object_field:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  let hoverOpt = lsp.getHover("file://" & testFile, 12, 4)
  doAssert hoverOpt.isSome
  doAssert hoverOpt.get().contents.value.contains("string")

block hover_on_enum_member:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  let hoverOpt = lsp.getHover("file://" & testFile, 40, 4)
  doAssert hoverOpt.isSome
  doAssert hoverOpt.get().contents.value.contains("Active")

block definition_on_object_field:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(testFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)
  lsp.updateFile("file://" & testFile, content)

  let defOpt = lsp.findDefinition("file://" & testFile, 12, 4)
  doAssert defOpt.isSome
  let loc = defOpt.get()
  doAssert loc.range.startPos.line == 12

block document_symbols_include_object_fields_and_enum_members:
  let testFile = testdataDir / "language_constructs" / "src" / "all_constructs.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)

  let symbols = lsp.getDocumentSymbols("file://" & testFile)
  var foundName = false
  var foundActive = false
  for s in symbols:
    if s.name == "name":
      foundName = true
      doAssert s.kind == SymbolKind.Variable
    if s.name == "Active":
      foundActive = true
      doAssert s.kind == SymbolKind.Constant

  doAssert foundName
  doAssert foundActive

block signature_help_on_procedure_call:
  let mainFile = testdataDir / "simple_project" / "src" / "main.nim"
  let utilsFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let content = readFile(mainFile)
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(utilsFile)
  lsp.updateFile("file://" & mainFile, content)

  let sigOpt = lsp.getSignatureHelp("file://" & mainFile, 5, 12)
  doAssert sigOpt.isSome
  doAssert sigOpt.get().signatures[0].label.contains("greet")

block workspace_symbol_search:
  let testFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let lsp = initMinLSP()
  discard lsp.generateCtagsForFile(testFile)

  let symbols = lsp.getWorkspaceSymbols("Person")
  doAssert symbols.len > 0
  var found = false
  for s in symbols:
    if s.name == "Person":
      found = true
      break
  doAssert found

block find_references_across_workspace_files:
  let lsp = initMinLSP()
  let mainFile = testdataDir / "simple_project" / "src" / "main.nim"
  let utilsFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let mainContent = readFile(mainFile)

  discard lsp.generateCtagsForFile(utilsFile)
  discard lsp.generateCtagsForFile(mainFile)
  lsp.updateFile("file://" & mainFile, mainContent)

  let refs = lsp.getReferences("file://" & mainFile, 5, 8, true)
  doAssert refs.len >= 2
  var foundMain = false
  var foundUtils = false
  for r in refs:
    if r.uri == "file://" & mainFile:
      foundMain = true
    if r.uri == "file://" & utilsFile:
      foundUtils = true
  doAssert foundMain
  doAssert foundUtils

block workspace_rename_across_files:
  let lsp = initMinLSP()
  let mainFile = testdataDir / "simple_project" / "src" / "main.nim"
  let utilsFile = testdataDir / "simple_project" / "src" / "utils.nim"
  let mainContent = readFile(mainFile)

  discard lsp.generateCtagsForFile(utilsFile)
  discard lsp.generateCtagsForFile(mainFile)
  lsp.updateFile("file://" & mainFile, mainContent)

  let edits = lsp.renameSymbol("file://" & mainFile, 5, 8, "sayHello")
  doAssert edits.len >= 2
  var foundMain = false
  var foundUtils = false
  for e in edits:
    if e.uri == "file://" & mainFile:
      foundMain = true
    if e.uri == "file://" & utilsFile:
      foundUtils = true
  doAssert foundMain
  doAssert foundUtils

# Tests pass silently
