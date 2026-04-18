import std/[asyncdispatch, asyncfile, json, options, os, osproc, sets, streams, strformat, strutils, tables, terminal, times]
import minlsp/[ntagger, logger]
import compiler/[ast, syntaxes, options, pathutils, idents, msgs]
import minlsp/baseprotocol

# Types
type
  MinLSP* = ref object
    ctagsCache*: Table[string, seq[Tag]]
    openFiles*: Table[string, string]
    pendingUpdates: Table[string, int]
    rootPath*: string
    initialized*: bool
    shutdownRequested*: bool
    conf: ConfigRef
    cache: IdentCache
    tagIndex: Table[string, seq[Tag]]   # maps tag.name -> all tags with that name

  Position* = object
    line*: int
    character*: int

  Range* = object
    startPos*: Position
    endPos*: Position

  Location* = object
    uri*: string
    range*: Range

  MarkupKind* = enum
    PlainText = "plaintext"
    Markdown = "markdown"

  MarkupContent* = object
    kind*: MarkupKind
    value*: string

  Hover* = object
    contents*: MarkupContent

  CompletionItemKind* = enum
    Text = 1
    Method = 2
    Function = 3
    Constructor = 4
    Field = 5
    Variable = 6
    Class = 7
    Interface = 8
    Module = 9
    Property = 10
    Unit = 11
    Value = 12
    Enum = 13
    Keyword = 14
    Snippet = 15
    Color = 16
    File = 17
    Reference = 18

  CompletionItem* = object
    label*: string
    kind*: CompletionItemKind
    detail*: string
    documentation*: string

  SymbolKind* = enum
    File = 1
    Module = 2
    Namespace = 3
    Package = 4
    Class = 5
    Method = 6
    Property = 7
    Field = 8
    Constructor = 9
    Enum = 10
    Interface = 11
    Function = 12
    Variable = 13
    Constant = 14
    String = 15
    Number = 16
    Boolean = 17
    Array = 18
    Object = 19
    Key = 20
    Null = 21
    EnumMember = 22
    Struct = 23
    Event = 24
    Operator = 25
    TypeParameter = 26

  DocumentSymbol* = object
    name*: string
    kind*: SymbolKind
    range*: Range
    selectionRange*: Range
    detail*: string
    uri*: string

  LSPMessage* = object
    jsonrpc*: string
    id*: Option[JsonNode]
    lspMethod*: Option[string]
    params*: Option[JsonNode]
    result*: Option[JsonNode]
    error*: Option[JsonNode]

  SignatureInformation* = object
    label*: string
    documentation*: string
    parameters*: seq[ParameterInformation]

  ParameterInformation* = object
    label*: string
    documentation*: string

  SignatureHelp* = object
    signatures*: seq[SignatureInformation]
    activeSignature*: int
    activeParameter*: int

# Helper functions
# MinLSP implementation
proc initMinLSP*(): MinLSP =
  let conf = newConfigRef()
  conf.errorMax = high(int)
  result = MinLSP(
    ctagsCache: initTable[string, seq[Tag]](),
    openFiles: initTable[string, string](),
    pendingUpdates: initTable[string, int](),
    rootPath: "",
    initialized: false,
    shutdownRequested: false,
    conf: conf,
    cache: newIdentCache(),
    tagIndex: initTable[string, seq[Tag]]()
  )

proc rebuildTagIndex(lsp: MinLSP) =
  lsp.tagIndex.clear()
  for filePath, tags in lsp.ctagsCache:
    for tag in tags:
      if not lsp.tagIndex.hasKey(tag.name):
        lsp.tagIndex[tag.name] = @[]
      lsp.tagIndex[tag.name].add(tag)

proc generateCtagsForFile*(lsp: MinLSP, filePath: string): seq[Tag] =
  try:
    result = collectTagsForFile(lsp.conf, lsp.cache, filePath, includePrivate = true)
    lsp.ctagsCache[filePath] = result
    lsp.rebuildTagIndex()
    infoLog("Generated ", $result.len, " tags for ", filePath)
  except:
    errorLog("Failed to generate ctags for ", filePath, ": ", getCurrentExceptionMsg())
    result = @[]

proc extractLine(content: string, line: int): string =
  ## Extract a single line from `content` without splitting the whole file.
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
  result = content[start ..< i]

proc extractWordAtPosition(content: string, line, character: int): tuple[word: string, lineStart, colStart, lineEnd, colEnd: int] =
  let currentLine = extractLine(content, line)
  if currentLine.len == 0 and (line > 0 or content.len == 0):
    return ("", 0, 0, 0, 0)
  if character >= currentLine.len:
    return ("", 0, 0, 0, 0)
  var start = character
  var wordEnd = character
  while start > 0 and currentLine[start-1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    dec(start)
  while wordEnd < currentLine.len and currentLine[wordEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    inc(wordEnd)
  if start >= wordEnd:
    return ("", 0, 0, 0, 0)
  result.word = currentLine[start..<wordEnd]
  result.lineStart = line
  result.colStart = start
  result.lineEnd = line
  result.colEnd = wordEnd

proc findDefinition*(lsp: MinLSP, fileUri: string, line: int, character: int): seq[Location] =
  let filePath = uriToPath(fileUri)
  let content = lsp.openFiles.getOrDefault(filePath, "")
  let (word, _, _, _, _) = extractWordAtPosition(content, line, character)
  if word.len == 0:
    return @[]

  let defKinds = {tkProc, tkFunc, tkMethod, tkMacro, tkTemplate, tkType, tkVar, tkLet, tkConst}
  let candidates = lsp.tagIndex.getOrDefault(word)

  # Only return a result when the cursor is on the definition line itself.
  # Without semantic analysis we cannot disambiguate overloads at call sites.
  for tag in candidates:
    if tag.kind notin defKinds:
      continue
    if tag.file == filePath and (tag.line - 1) == line:
      return @[Location(
        uri: pathToUri(tag.file),
        range: Range(
          startPos: Position(line: tag.line - 1, character: 0),
          endPos: Position(line: tag.line - 1, character: 0)
        )
      )]

proc getCompletions*(lsp: MinLSP, fileUri: string, line: int, character: int): seq[CompletionItem] =
  let filePath = uriToPath(fileUri)
  let content = lsp.openFiles.getOrDefault(filePath, "")
  let (word, _, _, _, _) = extractWordAtPosition(content, line, character)

  const maxResults = 100
  var seen = initHashSet[string]()
  result = @[]

  if lsp.ctagsCache.hasKey(filePath):
    for tag in lsp.ctagsCache[filePath]:
      if tag.name.startsWith(word) and not seen.contains(tag.name):
        seen.incl(tag.name)
        let kind = case tag.kind
        of tkProc, tkFunc: CompletionItemKind.Function
        of tkMethod: CompletionItemKind.Method
        of tkType: CompletionItemKind.Class
        of tkVar: CompletionItemKind.Variable
        of tkLet, tkConst: CompletionItemKind.Value
        of tkMacro: CompletionItemKind.Function
        of tkTemplate: CompletionItemKind.Snippet
        else: CompletionItemKind.Text
        result.add(CompletionItem(
          label: tag.name,
          kind: kind,
          detail: tag.signature,
          documentation: ""
        ))
      if result.len >= maxResults:
        return

  for file, tags in lsp.ctagsCache:
    if file == filePath:
      continue
    for tag in tags:
      if tag.name.startsWith(word) and not seen.contains(tag.name):
        seen.incl(tag.name)
        let kind = case tag.kind
        of tkProc, tkFunc: CompletionItemKind.Function
        of tkMethod: CompletionItemKind.Method
        of tkType: CompletionItemKind.Class
        of tkVar: CompletionItemKind.Variable
        of tkLet, tkConst: CompletionItemKind.Value
        of tkMacro: CompletionItemKind.Function
        of tkTemplate: CompletionItemKind.Snippet
        else: CompletionItemKind.Text
        result.add(CompletionItem(
          label: tag.name,
          kind: kind,
          detail: tag.signature,
          documentation: ""
        ))
      if result.len >= maxResults:
        return

proc buildHoverText(tag: Tag): string =
  let kindStr = tagKindName(tag.kind)
  let displaySig = if tag.signature.len > 0:
                     kindStr & " " & tag.name & tag.signature
                   else:
                     kindStr & " " & tag.name
  result = "```nim\n" & displaySig & "\n```"
  if tag.docComment.len > 0:
    result.add("\n\n" & tag.docComment.strip())

proc getHover*(lsp: MinLSP, fileUri: string, line: int, character: int): Option[Hover] =
  let filePath = uriToPath(fileUri)
  let content = lsp.openFiles.getOrDefault(filePath, "")
  let (word, _, _, _, _) = extractWordAtPosition(content, line, character)
  if word.len == 0:
    return none(Hover)

  var matches: seq[Tag] = @[]
  let candidates = lsp.tagIndex.getOrDefault(word)
  for tag in candidates:
    if tag.file == filePath and (tag.line - 1) == line:
      matches.add(tag)
  if matches.len == 0:
    for tag in candidates:
      matches.add(tag)

  if matches.len == 0:
    return none(Hover)
  elif matches.len == 1:
    return some(Hover(
      contents: MarkupContent(
        kind: MarkupKind.Markdown,
        value: buildHoverText(matches[0])
      )
    ))
  else:
    var text = ""
    for i, tag in matches:
      text.add(buildHoverText(tag))
      if i < matches.high:
        text.add("\n\n---\n\n")
    return some(Hover(
      contents: MarkupContent(
        kind: MarkupKind.Markdown,
        value: text
      )
    ))

proc getSignatureHelp*(lsp: MinLSP, fileUri: string, line: int, character: int): Option[SignatureHelp] =
  let filePath = uriToPath(fileUri)
  let content = lsp.openFiles.getOrDefault(filePath, "")
  let currentLine = extractLine(content, line)
  if currentLine.len == 0 and (line > 0 or content.len == 0):
    return none(SignatureHelp)
  # Find the word before the opening paren at or before character
  var pos = min(character, currentLine.len - 1)
  if pos < 0: return none(SignatureHelp)
  # Skip whitespace backward
  while pos >= 0 and currentLine[pos] in {' ', '\t'}:
    dec(pos)
  # Skip closing parens to handle nested calls
  var parenDepth = 0
  while pos >= 0:
    let c = currentLine[pos]
    if c == ')':
      inc(parenDepth)
    elif c == '(':
      if parenDepth > 0:
        dec(parenDepth)
      else:
        break
    elif parenDepth == 0 and c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      break
    dec(pos)
  if pos < 0:
    return none(SignatureHelp)
  # If we stopped at an opening paren, step back before it
  if currentLine[pos] == '(':
    dec(pos)
  while pos >= 0 and currentLine[pos] in {' ', '\t'}:
    dec(pos)
  if pos < 0:
    return none(SignatureHelp)
  var start = pos
  while start >= 0 and currentLine[start] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    dec(start)
  inc(start)
  if start > pos:
    return none(SignatureHelp)
  let word = currentLine[start..pos]

  let sigKinds = {tkProc, tkFunc, tkMethod, tkMacro, tkTemplate, tkConverter, tkIterator}
  var matches: seq[Tag] = @[]

  let candidates = lsp.tagIndex.getOrDefault(word)
  for tag in candidates:
    if tag.kind notin sigKinds:
      continue
    if tag.file == filePath and (tag.line - 1) == line:
      matches.add(tag)
  if matches.len == 0:
    for tag in candidates:
      if tag.kind notin sigKinds:
        continue
      matches.add(tag)

  if matches.len == 0:
    return none(SignatureHelp)

  var signatures: seq[SignatureInformation] = @[]
  for tag in matches:
    var label = tag.name
    if tag.signature.len > 0:
      label = tag.name & tag.signature
    else:
      label = tagKindName(tag.kind) & " " & tag.name & "()"
    var params: seq[ParameterInformation] = @[]
    # Simple parameter extraction from signature like (a: int, b: string)
    if tag.signature.len > 2 and tag.signature.startsWith("(") and tag.signature.endsWith(")"):
      let inner = tag.signature[1..^2]
      for raw in inner.split(","):
        let p = raw.strip()
        if p.len > 0:
          params.add(ParameterInformation(label: p, documentation: ""))
    signatures.add(SignatureInformation(
      label: label,
      documentation: tag.docComment,
      parameters: params
    ))

  return some(SignatureHelp(
    signatures: signatures,
    activeSignature: 0,
    activeParameter: 0
  ))

proc scanWordOccurrences(text, word: string): seq[tuple[line, col: int]] =
  var pos = 0
  var line = 0
  var lineStart = 0
  while true:
    let idx = text.find(word, pos)
    if idx == -1:
      break
    for i in pos ..< idx:
      if text[i] == '\n':
        inc line
        lineStart = i + 1
    let leftOk = idx == 0 or text[idx-1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}
    let rightOk = idx + word.len >= text.len or text[idx + word.len] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}
    if leftOk and rightOk:
      result.add((line: line, col: idx - lineStart))
    pos = idx + word.len

proc getReferences*(lsp: MinLSP, fileUri: string, line: int, character: int, includeDeclaration: bool): seq[Location] =
  let filePath = uriToPath(fileUri)
  let content = lsp.openFiles.getOrDefault(filePath, "")
  let (word, _, _, _, _) = extractWordAtPosition(content, line, character)
  if word.len == 0:
    return
  var processed = initHashSet[string]()
  # Search all workspace files for occurrences
  for path in lsp.ctagsCache.keys:
    processed.incl(path)
    let text = try:
      if lsp.openFiles.hasKey(path): lsp.openFiles[path] else: readFile(path)
    except CatchableError:
      continue
    for occ in scanWordOccurrences(text, word):
      result.add(Location(
        uri: pathToUri(path),
        range: Range(
          startPos: Position(line: occ.line, character: occ.col),
          endPos: Position(line: occ.line, character: occ.col + word.len)
        )
      ))
  # Also search open files that might not be in ctagsCache yet
  for path in lsp.openFiles.keys:
    if path in processed:
      continue
    let text = lsp.openFiles[path]
    for occ in scanWordOccurrences(text, word):
      result.add(Location(
        uri: pathToUri(path),
        range: Range(
          startPos: Position(line: occ.line, character: occ.col),
          endPos: Position(line: occ.line, character: occ.col + word.len)
        )
      ))

proc getWorkspaceSymbols*(lsp: MinLSP, query: string): seq[DocumentSymbol] =
  if query.len == 0:
    return
  let lowerQuery = query.toLowerAscii()
  for file, tags in lsp.ctagsCache:
    for tag in tags:
      if tag.name.toLowerAscii().contains(lowerQuery):
        let kind = case tag.kind
        of tkModule: SymbolKind.Module
        of tkProc, tkFunc: SymbolKind.Function
        of tkMethod: SymbolKind.Method
        of tkType: SymbolKind.Class
        of tkVar: SymbolKind.Variable
        of tkLet: SymbolKind.Constant
        of tkConst: SymbolKind.Constant
        of tkMacro: SymbolKind.Function
        of tkTemplate: SymbolKind.Function
        else: SymbolKind.Variable
        result.add(DocumentSymbol(
          name: tag.name,
          kind: kind,
          range: Range(
            startPos: Position(line: tag.line - 1, character: 0),
            endPos: Position(line: tag.line - 1, character: 0)
          ),
          selectionRange: Range(
            startPos: Position(line: tag.line - 1, character: 0),
            endPos: Position(line: tag.line - 1, character: 0)
          ),
          detail: tag.signature,
          uri: pathToUri(file)
        ))

proc getDiagnostics*(lsp: MinLSP, fileUri: string): seq[tuple[message: string, line, col: int, severity: int]] =
  let filePath = uriToPath(fileUri)
  if not lsp.openFiles.hasKey(filePath):
    return
  let content = lsp.openFiles[filePath]
  # Simple syntax check: try to parse with the compiler
  let abs = AbsoluteFile(absolutePath(filePath))
  let idx = fileInfoIdx(lsp.conf, abs)
  # We can't easily intercept compiler messages, but we can check for nil AST
  # and also do a basic brace/paren balance check
  var ast: PNode = nil
  try:
    ast = syntaxes.parseFile(idx, lsp.cache, lsp.conf)
  except CatchableError:
    discard
  # Also run nimpretty --check if available? Too expensive.
  # Return empty for now unless AST is nil (severe parse failure)
  if ast.isNil:
    result.add((message: "Syntax error: failed to parse file", line: 0, col: 0, severity: 1))

proc formatDocument*(lsp: MinLSP, fileUri: string): Option[string] =
  let filePath = uriToPath(fileUri)
  if not lsp.openFiles.hasKey(filePath):
    return none(string)
  let nimpretty = findExe("nimpretty")
  if nimpretty.len == 0:
    return none(string)
  let content = lsp.openFiles[filePath]
  # Write to temp file, run nimpretty, read back
  let tmpFile = getTempDir() / "minlsp_format_" & $getCurrentProcessId() & ".nim"
  try:
    writeFile(tmpFile, content)
    let (_, exitCode) = execCmdEx(nimpretty & " " & quoteShell(tmpFile))
    if exitCode == 0:
      let formatted = readFile(tmpFile)
      removeFile(tmpFile)
      return some(formatted)
    removeFile(tmpFile)
  except CatchableError:
    discard
  return none(string)

proc renameSymbol*(lsp: MinLSP, fileUri: string, line: int, character: int, newName: string): seq[tuple[uri: string, startLine, startCol, endLine, endCol: int]] =
  let filePath = uriToPath(fileUri)
  let content = lsp.openFiles.getOrDefault(filePath, "")
  let (word, _, _, _, _) = extractWordAtPosition(content, line, character)
  if word.len == 0 or newName.len == 0:
    return
  var processed = initHashSet[string]()
  for path in lsp.ctagsCache.keys:
    processed.incl(path)
    let text = try:
      if lsp.openFiles.hasKey(path): lsp.openFiles[path] else: readFile(path)
    except CatchableError:
      continue
    for occ in scanWordOccurrences(text, word):
      result.add((uri: pathToUri(path), startLine: occ.line, startCol: occ.col, endLine: occ.line, endCol: occ.col + word.len))
  # Also include open files that might not be in ctagsCache yet
  for path in lsp.openFiles.keys:
    if path in processed:
      continue
    let text = lsp.openFiles[path]
    for occ in scanWordOccurrences(text, word):
      result.add((uri: pathToUri(path), startLine: occ.line, startCol: occ.col, endLine: occ.line, endCol: occ.col + word.len))

proc getDocumentSymbols*(lsp: MinLSP, fileUri: string): seq[DocumentSymbol] =
  let filePath = uriToPath(fileUri)
  
  if lsp.ctagsCache.hasKey(filePath):
    for tag in lsp.ctagsCache[filePath]:
      let kind = case tag.kind
      of tkModule: SymbolKind.Module
      of tkProc, tkFunc: SymbolKind.Function
      of tkMethod: SymbolKind.Method
      of tkType: SymbolKind.Class
      of tkVar: SymbolKind.Variable
      of tkLet: SymbolKind.Constant
      of tkConst: SymbolKind.Constant
      of tkMacro: SymbolKind.Function
      of tkTemplate: SymbolKind.Function
      else: SymbolKind.Variable
      
      result.add(DocumentSymbol(
        name: tag.name,
        kind: kind,
        range: Range(
          startPos: Position(line: tag.line - 1, character: 0),
          endPos: Position(line: tag.line - 1, character: 0)
        ),
        selectionRange: Range(
          startPos: Position(line: tag.line - 1, character: 0),
          endPos: Position(line: tag.line - 1, character: 0)
        ),
        detail: tag.signature,
        uri: fileUri
      ))

proc debouncedGenerateCtags(lsp: MinLSP, filePath: string, expectedTick: int) {.async.} =
  await sleepAsync(300)
  if lsp.pendingUpdates.getOrDefault(filePath, 0) == expectedTick:
    lsp.pendingUpdates.del(filePath)
    discard lsp.generateCtagsForFile(filePath)

proc updateFile*(lsp: MinLSP, fileUri: string, content: string, immediate: bool = false) =
  let filePath = uriToPath(fileUri)
  lsp.openFiles[filePath] = content
  if immediate:
    lsp.pendingUpdates.del(filePath)
    discard lsp.generateCtagsForFile(filePath)
  else:
    let tick = lsp.pendingUpdates.getOrDefault(filePath, 0) + 1
    lsp.pendingUpdates[filePath] = tick
    asyncCheck lsp.debouncedGenerateCtags(filePath, tick)

proc removeFile*(lsp: MinLSP, fileUri: string) =
  let filePath = uriToPath(fileUri)
  lsp.openFiles.del(filePath)
  lsp.ctagsCache.del(filePath)
  lsp.pendingUpdates.del(filePath)

# LSP Protocol - using baseprotocol from nimlsp

# Global LSP instance
var lspInstance: MinLSP

proc initLSP() =
  lspInstance = initMinLSP()

proc scanProjectAsync*(lsp: MinLSP) {.async.} =
  if lsp.rootPath.len > 0 and dirExists(lsp.rootPath):
    infoLog("Scanning project...")
    let tags = generateCtagsForDir([lsp.rootPath], excludes = ["deps", "tests"], includePrivate = true)
    for tag in tags:
      if not lsp.ctagsCache.hasKey(tag.file):
        lsp.ctagsCache[tag.file] = @[]
      lsp.ctagsCache[tag.file].add(tag)
    lsp.rebuildTagIndex()
    infoLog("Scanned project, found ", $tags.len, " tags")

    infoLog("Scanning standard library...")
    var stdRoots: seq[string]
    for pth in searchPaths():
      if pth.len == 0 or not dirExists(pth):
        continue
      # Skip dependency directories to avoid indexing installed packages as stdlib
      if pth.endsWith("nimble") or pth.contains("/deps/") or pth.contains("\\deps\\"):
        continue
      stdRoots.add(pth)
    if stdRoots.len > 0:
      let stdTags = generateCtagsForDir(stdRoots, excludes = ["deps", "tests"],
                                          includePrivate = true)
      for tag in stdTags:
        if not lsp.ctagsCache.hasKey(tag.file):
          lsp.ctagsCache[tag.file] = @[]
        lsp.ctagsCache[tag.file].add(tag)
      lsp.rebuildTagIndex()
      infoLog("Scanned stdlib, found ", $stdTags.len, " tags")

proc handleInitialize(lsp: MinLSP, params: JsonNode): JsonNode =
  # Extract root path from initialize params
  if params.hasKey("rootPath") and params["rootPath"].kind != JNull:
    lsp.rootPath = params["rootPath"].getStr
  elif params.hasKey("rootUri") and params["rootUri"].kind != JNull:
    var rootUri = params["rootUri"].getStr
    if rootUri.startsWith("file://"):
      rootUri = rootUri[7..^1]
    lsp.rootPath = rootUri
  
  infoLog("Project root: ", lsp.rootPath)
  
  lsp.initialized = true
  
  result = %*{
    "capabilities": {
      "textDocumentSync": {
        "openClose": true,
        "change": 1,
        "willSave": false,
        "willSaveWaitUntil": false,
        "save": {
          "includeText": false
        }
      },
      "completionProvider": {
        "resolveProvider": false,
        "triggerCharacters": ["."]
      },
      "hoverProvider": true,
      "definitionProvider": true,
      "documentSymbolProvider": true,
      "referencesProvider": true,
      "signatureHelpProvider": {
        "triggerCharacters": ["(", ","]
      },
      "renameProvider": true,
      "workspaceSymbolProvider": true,
      "documentFormattingProvider": true,
      "documentRangeFormattingProvider": false,
      "diagnosticProvider": {
        "interFileDependencies": false,
        "workspaceDiagnostics": false
      }
    },
    "serverInfo": {
      "name": "minlsp",
      "version": "0.1.0"
    }
  }

proc handleShutdown(lsp: MinLSP): JsonNode =
  lsp.shutdownRequested = true
  result = newJNull()

proc handleTextDocumentDidOpen(lsp: MinLSP, params: JsonNode) =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let text = textDocument["text"].getStr
  lsp.updateFile(uri, text, immediate = true)

proc handleTextDocumentDidChange(lsp: MinLSP, params: JsonNode) =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let contentChanges = params["contentChanges"]
  if contentChanges.len > 0:
    let newText = contentChanges[0]["text"].getStr
    lsp.updateFile(uri, newText)

proc handleTextDocumentDidClose(lsp: MinLSP, params: JsonNode) =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  lsp.removeFile(uri)

proc handleTextDocumentCompletion(lsp: MinLSP, params: JsonNode): JsonNode =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let position = params["position"]
  let line = position["line"].getInt
  let character = position["character"].getInt
  
  let completions = lsp.getCompletions(uri, line, character)
  
  var items: seq[JsonNode]
  for completion in completions:
    items.add(%*{
      "label": completion.label,
      "kind": ord(completion.kind),
      "detail": completion.detail,
      "documentation": completion.documentation
    })
  
  result = %items

proc handleTextDocumentHover(lsp: MinLSP, params: JsonNode): JsonNode =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let position = params["position"]
  let line = position["line"].getInt
  let character = position["character"].getInt
  
  let hoverOpt = lsp.getHover(uri, line, character)
  
  if hoverOpt.isSome:
    let hover = hoverOpt.get()
    result = %*{
      "contents": {
        "kind": $hover.contents.kind,
        "value": hover.contents.value
      }
    }
  else:
    result = newJNull()

proc handleTextDocumentDefinition(lsp: MinLSP, params: JsonNode): JsonNode =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let position = params["position"]
  let line = position["line"].getInt
  let character = position["character"].getInt

  let definitions = lsp.findDefinition(uri, line, character)

  if definitions.len == 0:
    result = newJNull()
  elif definitions.len == 1:
    let definition = definitions[0]
    result = %*{
      "uri": definition.uri,
      "range": {
        "start": {
          "line": definition.range.startPos.line,
          "character": definition.range.startPos.character
        },
        "end": {
          "line": definition.range.endPos.line,
          "character": definition.range.endPos.character
        }
      }
    }
  else:
    result = newJArray()
    for definition in definitions:
      result.add(%*{
        "uri": definition.uri,
        "range": {
          "start": {
            "line": definition.range.startPos.line,
            "character": definition.range.startPos.character
          },
          "end": {
            "line": definition.range.endPos.line,
            "character": definition.range.endPos.character
          }
        }
      })

proc handleTextDocumentSignatureHelp(lsp: MinLSP, params: JsonNode): JsonNode =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let position = params["position"]
  let line = position["line"].getInt
  let character = position["character"].getInt

  let sigOpt = lsp.getSignatureHelp(uri, line, character)
  if sigOpt.isSome:
    let sig = sigOpt.get()
    var sigs: seq[JsonNode] = @[]
    for s in sig.signatures:
      var paramsJson: seq[JsonNode] = @[]
      for p in s.parameters:
        paramsJson.add(%*{"label": p.label, "documentation": p.documentation})
      sigs.add(%*{
        "label": s.label,
        "documentation": s.documentation,
        "parameters": paramsJson
      })
    result = %*{
      "signatures": sigs,
      "activeSignature": sig.activeSignature,
      "activeParameter": sig.activeParameter
    }
  else:
    result = newJNull()

proc handleTextDocumentReferences(lsp: MinLSP, params: JsonNode): JsonNode =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let position = params["position"]
  let line = position["line"].getInt
  let character = position["character"].getInt
  let includeDecl = if params.hasKey("context") and params["context"].hasKey("includeDeclaration"):
                      params["context"]["includeDeclaration"].getBool
                    else:
                      true

  let refs = lsp.getReferences(uri, line, character, includeDecl)
  var items: seq[JsonNode] = @[]
  for loc in refs:
    items.add(%*{
      "uri": loc.uri,
      "range": {
        "start": {"line": loc.range.startPos.line, "character": loc.range.startPos.character},
        "end": {"line": loc.range.endPos.line, "character": loc.range.endPos.character}
      }
    })
  result = %items

proc handleTextDocumentRename(lsp: MinLSP, params: JsonNode): JsonNode =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let position = params["position"]
  let line = position["line"].getInt
  let character = position["character"].getInt
  let newName = params["newName"].getStr

  let edits = lsp.renameSymbol(uri, line, character, newName)
  var docEdits: seq[JsonNode] = @[]
  for e in edits:
    docEdits.add(%*{
      "uri": e.uri,
      "range": {
        "start": {"line": e.startLine, "character": e.startCol},
        "end": {"line": e.endLine, "character": e.endCol}
      },
      "newText": newName
    })
  result = %*{
    "documentChanges": [%*{
      "textDocument": {"version": nil, "uri": uri},
      "edits": docEdits
    }]
  }

proc handleWorkspaceSymbol(lsp: MinLSP, params: JsonNode): JsonNode =
  let query = if params.hasKey("query"): params["query"].getStr else: ""
  let symbols = lsp.getWorkspaceSymbols(query)
  var items: seq[JsonNode] = @[]
  for s in symbols:
    items.add(%*{
      "name": s.name,
      "kind": ord(s.kind),
      "location": {
        "uri": s.uri,
        "range": {
          "start": {"line": s.range.startPos.line, "character": s.range.startPos.character},
          "end": {"line": s.range.endPos.line, "character": s.range.endPos.character}
        }
      }
    })
  # Fix: we need the file path for workspace symbols
  result = %items

proc handleTextDocumentFormatting(lsp: MinLSP, params: JsonNode): JsonNode =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let formattedOpt = lsp.formatDocument(uri)
  if formattedOpt.isSome:
    result = %*[{
      "range": {
        "start": {"line": 0, "character": 0},
        "end": {"line": 999999, "character": 999999}
      },
      "newText": formattedOpt.get()
    }]
  else:
    result = newJNull()

proc handleTextDocumentDiagnostic(lsp: MinLSP, params: JsonNode): JsonNode =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  let diags = lsp.getDiagnostics(uri)
  var items: seq[JsonNode] = @[]
  for d in diags:
    items.add(%*{
      "range": {
        "start": {"line": d.line, "character": d.col},
        "end": {"line": d.line, "character": d.col + 1}
      },
      "severity": d.severity,
      "message": d.message
    })
  result = %*{
    "kind": "full",
    "items": items
  }

proc handleTextDocumentDocumentSymbol(lsp: MinLSP, params: JsonNode): JsonNode =
  let textDocument = params["textDocument"]
  let uri = textDocument["uri"].getStr
  
  let symbols = lsp.getDocumentSymbols(uri)
  
  var items: seq[JsonNode]
  for symbol in symbols:
    items.add(%*{
      "name": symbol.name,
      "kind": ord(symbol.kind),
      "range": {
        "start": {
          "line": symbol.range.startPos.line,
          "character": symbol.range.startPos.character
        },
        "end": {
          "line": symbol.range.endPos.line,
          "character": symbol.range.endPos.character
        }
      },
      "selectionRange": {
        "start": {
          "line": symbol.selectionRange.startPos.line,
          "character": symbol.selectionRange.startPos.character
        },
        "end": {
          "line": symbol.selectionRange.endPos.line,
          "character": symbol.selectionRange.endPos.character
        }
      },
      "detail": symbol.detail
    })
  
  result = %items

proc handleMessage(lsp: MinLSP, message: LSPMessage, outs: AsyncFile) {.async.} =
  if message.lspMethod.isNone:
    debugLog("Message has no method, ignoring")
    return
    
  let lspMethod = message.lspMethod.get()
  let id = message.id
  let params = if message.params.isSome: message.params.get() else: newJNull()
  
  # Branch 1: Notifications (no id field)
  if id.isNone:
    debugLog("Handling notification: ", lspMethod)
    
    case lspMethod
    of "initialized":
      debugLog("Client initialized notification received")
    
    of "textDocument/didOpen":
      handleTextDocumentDidOpen(lsp, params)
    
    of "textDocument/didChange":
      handleTextDocumentDidChange(lsp, params)
    
    of "textDocument/didClose":
      handleTextDocumentDidClose(lsp, params)
    
    of "exit":
      debugLog("Exit notification received")
      lsp.shutdownRequested = true
    
    else:
      warnLog("Unknown notification: ", lspMethod)
    
    return
  
  # Branch 2: Requests (has id field - must send response)
  debugLog("Handling request: ", lspMethod, " (id: ", $id.get(), ")")
  let requestId = id.get()
  var result: JsonNode
  var handled = true
  
  case lspMethod
  of "initialize":
    debugLog("Processing initialize request...")
    result = handleInitialize(lsp, params)
    asyncCheck scanProjectAsync(lsp)
    debugLog("Initialize handled")
  
  of "shutdown":
    result = handleShutdown(lsp)
  
  of "textDocument/completion":
    result = handleTextDocumentCompletion(lsp, params)
  
  of "textDocument/hover":
    result = handleTextDocumentHover(lsp, params)
  
  of "textDocument/definition":
    result = handleTextDocumentDefinition(lsp, params)
  
  of "textDocument/documentSymbol":
    result = handleTextDocumentDocumentSymbol(lsp, params)

  of "textDocument/signatureHelp":
    result = handleTextDocumentSignatureHelp(lsp, params)

  of "textDocument/references":
    result = handleTextDocumentReferences(lsp, params)

  of "textDocument/rename":
    result = handleTextDocumentRename(lsp, params)

  of "workspace/symbol":
    result = handleWorkspaceSymbol(lsp, params)

  of "textDocument/formatting":
    result = handleTextDocumentFormatting(lsp, params)

  of "textDocument/diagnostic":
    result = handleTextDocumentDiagnostic(lsp, params)

  else:
    handled = false
    result = newJNull()
    await outs.sendJson(createErrorResponse(requestId, -32601, fmt"Method not found: {lspMethod}"))
  
  if handled:
    await outs.sendJson(createResponse(requestId, result))

proc main(ins: AsyncFile, outs: AsyncFile) {.async.} =
  ## Main server loop using async streams like nimlsp
  initLSP()
  
  infoLog("minlsp server started")
  
  var consecutiveErrors = 0
  const maxConsecutiveErrors = 5
  
  while not lspInstance.shutdownRequested:
    try:
      debugLog("Waiting for LSP message...")
      let frame = await ins.readFrame()
      debugLog("Got frame")
      
      let jsonNode = parseJson(frame)
      let message = LSPMessage(
        jsonrpc: jsonNode["jsonrpc"].getStr,
        id: if jsonNode.hasKey("id"): some(jsonNode["id"]) else: none(JsonNode),
        lspMethod: if jsonNode.hasKey("method"): some(jsonNode["method"].getStr) else: none(string),
        params: if jsonNode.hasKey("params"): some(jsonNode["params"]) else: none(JsonNode),
        result: if jsonNode.hasKey("result"): some(jsonNode["result"]) else: none(JsonNode),
        error: if jsonNode.hasKey("error"): some(jsonNode["error"]) else: none(JsonNode)
      )
      
      consecutiveErrors = 0
      infoLog("Received message, method: ", message.lspMethod.get("<none>"))
      await handleMessage(lspInstance, message, outs)
      infoLog("Message handled successfully")
    except ValueError:
      let msg = getCurrentExceptionMsg()
      errorLog("Protocol error: ", msg)
      consecutiveErrors += 1
      if consecutiveErrors >= maxConsecutiveErrors:
        errorLog("Too many consecutive errors, stopping server")
        break
    except IOError, OSError:
      let msg = getCurrentExceptionMsg()
      if msg.contains("EOF"):
        infoLog("Client disconnected (EOF)")
      else:
        infoLog("Client disconnected: ", msg)
      break
    except:
      let msg = getCurrentExceptionMsg()
      errorLog("Error processing message: ", msg)
      errorLog("Exception type: ", $getCurrentException().name)
      consecutiveErrors += 1
      if consecutiveErrors >= maxConsecutiveErrors:
        errorLog("Too many consecutive errors, stopping server")
        break
  
  infoLog("minlsp server stopped")

when isMainModule:
  var
    ins = newAsyncFile(stdin.getOsFileHandle().AsyncFD)
    outs = newAsyncFile(stdout.getOsFileHandle().AsyncFD)
  waitFor main(ins, outs)
