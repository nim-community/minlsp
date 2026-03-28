import std/[asyncdispatch, asyncfile, json, options, os, streams, strformat, strutils, tables, terminal, times]
import minlsp/[ntagger, logger]
import compiler/[options, pathutils, idents]
import minlsp/baseprotocol

# Types
type
  MinLSP* = ref object
    ctagsCache*: Table[string, seq[Tag]]
    openFiles*: Table[string, string]
    rootPath*: string
    initialized*: bool
    shutdownRequested*: bool
    conf: ConfigRef
    cache: IdentCache

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
  result = MinLSP(
    ctagsCache: initTable[string, seq[Tag]](),
    openFiles: initTable[string, string](),
    rootPath: "",
    initialized: false,
    shutdownRequested: false,
    conf: newConfigRef(),
    cache: newIdentCache()
  )

proc generateCtagsForFile*(lsp: MinLSP, filePath: string): seq[Tag] =
  if lsp.ctagsCache.hasKey(filePath):
    return lsp.ctagsCache[filePath]
  
  try:
    result = collectTagsForFile(lsp.conf, lsp.cache, filePath, includePrivate = true)
    lsp.ctagsCache[filePath] = result
    infoLog("Generated ", $result.len, " tags for ", filePath)
  except:
    errorLog("Failed to generate ctags for ", filePath, ": ", getCurrentExceptionMsg())
    result = @[]

proc findDefinition*(lsp: MinLSP, fileUri: string, line: int, character: int): Option[Location] =
  let filePath = uriToPath(fileUri)
  let content = lsp.openFiles.getOrDefault(filePath, "")
  let lines = content.splitLines
  if line >= lines.len:
    return none(Location)
  
  let currentLine = lines[line]
  if character >= currentLine.len:
    return none(Location)
  
  var start = character
  var wordEnd = character
  
  while start > 0 and currentLine[start-1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    dec(start)
  
  while wordEnd < currentLine.len and currentLine[wordEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    inc(wordEnd)
  
  if start >= wordEnd:
    return none(Location)
  
  let word = currentLine[start..<wordEnd]
  
  for file, tags in lsp.ctagsCache:
    for tag in tags:
      if tag.name == word and tag.kind in {tkProc, tkFunc, tkMethod, tkMacro, tkTemplate, tkType, tkVar, tkLet, tkConst}:
        return some(Location(
          uri: pathToUri(tag.file),
          range: Range(
            startPos: Position(line: tag.line - 1, character: 0),
            endPos: Position(line: tag.line - 1, character: 0)
          )
        ))
  
  return none(Location)

proc getCompletions*(lsp: MinLSP, fileUri: string, line: int, character: int): seq[CompletionItem] =
  let filePath = uriToPath(fileUri)
  var symbols: seq[CompletionItem]
  
  if lsp.ctagsCache.hasKey(filePath):
    for tag in lsp.ctagsCache[filePath]:
      let kind = case tag.kind
      of tkProc, tkFunc: CompletionItemKind.Function
      of tkMethod: CompletionItemKind.Method
      of tkType: CompletionItemKind.Class
      of tkVar: CompletionItemKind.Variable
      of tkLet, tkConst: CompletionItemKind.Value
      of tkMacro: CompletionItemKind.Function
      of tkTemplate: CompletionItemKind.Snippet
      else: CompletionItemKind.Text
      
      symbols.add(CompletionItem(
        label: tag.name,
        kind: kind,
        detail: tag.signature,
        documentation: ""
      ))
  
  for file, tags in lsp.ctagsCache:
    if file != filePath:
      for tag in tags:
        let kind = case tag.kind
        of tkProc, tkFunc: CompletionItemKind.Function
        of tkMethod: CompletionItemKind.Method
        of tkType: CompletionItemKind.Class
        of tkVar: CompletionItemKind.Variable
        of tkLet, tkConst: CompletionItemKind.Value
        of tkMacro: CompletionItemKind.Function
        of tkTemplate: CompletionItemKind.Snippet
        else: CompletionItemKind.Text
        
        symbols.add(CompletionItem(
          label: tag.name,
          kind: kind,
          detail: tag.signature,
          documentation: ""
        ))
  
  return symbols

proc getHover*(lsp: MinLSP, fileUri: string, line: int, character: int): Option[Hover] =
  let filePath = uriToPath(fileUri)
  let content = lsp.openFiles.getOrDefault(filePath, "")
  let lines = content.splitLines
  if line >= lines.len:
    return none(Hover)
  
  let currentLine = lines[line]
  if character >= currentLine.len:
    return none(Hover)
  
  var start = character
  var wordEnd = character
  
  while start > 0 and currentLine[start-1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    dec(start)
  
  while wordEnd < currentLine.len and currentLine[wordEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    inc(wordEnd)
  
  if start >= wordEnd:
    return none(Hover)
  
  let word = currentLine[start..<wordEnd]
  
  for file, tags in lsp.ctagsCache:
    for tag in tags:
      if tag.name == word:
        let hoverText = fmt"{tag.name}: {tag.kind}\n{tag.signature}"
        return some(Hover(
          contents: MarkupContent(
            kind: MarkupKind.Markdown,
            value: hoverText
          )
        ))
  
  return none(Hover)

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
        detail: tag.signature
      ))

proc updateFile*(lsp: MinLSP, fileUri: string, content: string) =
  let filePath = uriToPath(fileUri)
  lsp.openFiles[filePath] = content
  discard lsp.generateCtagsForFile(filePath)

proc removeFile*(lsp: MinLSP, fileUri: string) =
  let filePath = uriToPath(fileUri)
  lsp.openFiles.del(filePath)
  lsp.ctagsCache.del(filePath)

# LSP Protocol - using baseprotocol from nimlsp

# Global LSP instance
var lspInstance: MinLSP

proc initLSP() =
  lspInstance = initMinLSP()

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
  
  # Scan project for tags
  if lsp.rootPath.len > 0 and dirExists(lsp.rootPath):
    infoLog("Scanning project...")
    let tags = generateCtagsForDir([lsp.rootPath], excludes = ["deps", "tests"], includePrivate = true)
    for tag in tags:
      if not lsp.ctagsCache.hasKey(tag.file):
        lsp.ctagsCache[tag.file] = @[]
      lsp.ctagsCache[tag.file].add(tag)
    infoLog("Scanned project, found ", $tags.len, " tags")
  
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
  lsp.updateFile(uri, text)

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
  
  let definitionOpt = lsp.findDefinition(uri, line, character)
  
  if definitionOpt.isSome:
    let definition = definitionOpt.get()
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
    result = newJNull()

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
