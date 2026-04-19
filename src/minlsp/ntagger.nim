import std/[os, strutils, algorithm, parseopt, osproc, threadpool]

import compiler/[ast, syntaxes, options, idents, msgs, pathutils, renderer, lineinfos]

type
  TagKind* = enum
    tkType, tkVar, tkLet, tkConst,
    tkProc, tkFunc, tkMethod, tkIterator,
    tkConverter, tkMacro, tkTemplate,
    tkModule

  Tag* = object
    name*: string
    file*: string
    line*: int
    kind*: TagKind
    signature*: string
    docComment*: string
    normName*: string

proc tagKindName*(k: TagKind): string =
  case k
  of tkType: "type"
  of tkVar: "var"
  of tkLet: "let"
  of tkConst: "const"
  of tkProc: "proc"
  of tkFunc: "func"
  of tkMethod: "method"
  of tkIterator: "iterator"
  of tkConverter: "converter"
  of tkMacro: "macro"
  of tkTemplate: "template"
  of tkModule: "module"

proc extractDocComment(n: PNode): string =
  ## Extracts the doc comment from a definition node.
  ## Nim stores doc comments as nkCommentStmt children inside bodies.
  if n.isNil: return ""
  if n.comment.len > 0:
    return n.comment
  # Atomic nodes (identifiers, literals, etc.) have no children
  if n.kind <= nkNilLit:
    return ""
  # For routine defs, the body (nkStmtList) is typically the last child
  if n.kind in {nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef,
                nkMacroDef, nkTemplateDef, nkConverterDef} and n.len > 6:
    let body = n[n.len - 1]
    if not body.isNil and body.kind == nkStmtList:
      for j in 0 ..< min(body.len, 3):
        let stmt = body[j]
        if stmt.isNil: continue
        if stmt.kind == nkCommentStmt and stmt.comment.len > 0:
          return stmt.comment
  # General fallback: search all children for nkCommentStmt or nested stmt lists
  for i in 0 ..< n.len:
    let child = n[i]
    if child.isNil: continue
    if child.kind == nkCommentStmt and child.comment.len > 0:
      return child.comment
    if child.kind == nkStmtList:
      for j in 0 ..< min(child.len, 3):
        let stmt = child[j]
        if stmt.isNil: continue
        if stmt.kind == nkCommentStmt and stmt.comment.len > 0:
          return stmt.comment
        if stmt.kind == nkStmtList and stmt.len > 0 and stmt[0].kind == nkCommentStmt and stmt[0].comment.len > 0:
          return stmt[0].comment
  ""

proc addTag(tags: var seq[Tag], file: string, line: int, name: string, k: TagKind,
            signature = "", docComment = "") =
  if name.len == 0:
    return
  tags.add Tag(name: name, file: file, line: line, kind: k,
      signature: signature, docComment: docComment, normName: nimIdentNormalize(name))

proc nodeName(n: PNode): string =
  ## Extracts the plain identifier name for a symbol definition node.
  ## Mirrors the logic of compiler/docgen.getNameIdent, but returns a
  ## simple string instead of an identifier.
  case n.kind
  of nkPostfix:
    result = nodeName(n[1])
  of nkPragmaExpr:
    result = nodeName(n[0])
  of nkSym:
    if n.sym != nil and n.sym.name != nil:
      result = n.sym.name.s
  of nkIdent:
    if n.ident != nil:
      result = n.ident.s
  of nkAccQuoted:
    for i in 0 ..< n.len:
      result.add nodeName(n[i])
  of nkOpenSymChoice, nkClosedSymChoice, nkOpenSym:
    result = nodeName(n[0])
  else:
    discard

proc isExportedName(n: PNode): bool =
  ## Returns true if a name node represents an exported symbol.
  ##
  ## We treat a ``nkPostfix`` name (e.g. ``foo*``) as exported and
  ## follow the same structural patterns as ``nodeName``.
  case n.kind
  of nkPostfix:
    result = true
  of nkPragmaExpr:
    result = isExportedName(n[0])
  of nkAccQuoted:
    result = isExportedName(n[0])
  of nkOpenSymChoice, nkClosedSymChoice, nkOpenSym:
    result = isExportedName(n[0])
  else:
    result = false

proc buildSignature(n: PNode): string =
  ## Builds a Nim-like signature string for routine definition nodes.
  ##
  ## The structure mirrors the JSON signature generation in
  ## deps/compiler/docgen.nim, but flattens it to a single string in
  ## the form: "[T](x: int, y: string = 0): int {. pragmas .}".

  # Generic parameters
  if n[genericParamsPos].kind != nkEmpty:
    result.add "["
    var firstGen = true
    for genericParam in n[genericParamsPos]:
      if not firstGen:
        result.add ", "
      firstGen = false
      result.add $genericParam
    result.add "]"

  # Parameters
  result.add "("
  if n[paramsPos].len > 1:
    var firstParam = true
    for paramIdx in 1 ..< n[paramsPos].len:
      let param = n[paramsPos][paramIdx]
      if param.kind == nkEmpty:
        continue

      let paramType = $param[^2]
      let defaultNode = param[^1]

      for identIdx in 0 ..< param.len - 2:
        let nameNode = param[identIdx]
        if nameNode.kind == nkEmpty:
          continue
        if not firstParam:
          result.add ", "
        firstParam = false
        result.add $nameNode
        if paramType.len > 0:
          result.add ": "
          result.add paramType
        if defaultNode.kind != nkEmpty:
          result.add " = "
          result.add $defaultNode
  result.add ")"

  # Return type
  if n[paramsPos][0].kind != nkEmpty:
    result.add ": "
    result.add $n[paramsPos][0]

  # Pragmas
  if n[pragmasPos].kind != nkEmpty:
    result.add " {. "
    var firstPragma = true
    for pragma in n[pragmasPos]:
      if not firstPragma:
        result.add ", "
      firstPragma = false
      result.add $pragma
    result.add " .}"

proc collectTagsFromAst(n: PNode, file: string, tags: var seq[Tag],
    includePrivate: bool)

proc collectFields(body: PNode, file: string, tags: var seq[Tag]) =
  if body.isNil: return
  case body.kind
  of nkObjectTy, nkTupleTy:
    if body.len > 2:
      collectFields(body[2], file, tags)
  of nkRecList:
    for child in body:
      if child.kind == nkIdentDefs and child.len >= 2:
        let fieldType = $child[^2]
        for k in 0 ..< child.len - 2:
          let fieldNode = child[k]
          if fieldNode.kind == nkEmpty:
            continue
          let fieldName = nodeName(fieldNode)
          if fieldName.len > 0:
            addTag(tags, file, int(child.info.line), fieldName, tkVar,
                   signature = if fieldType.len > 0: ": " & fieldType else: "",
                   docComment = extractDocComment(child))
      elif child.kind == nkRecCase:
        if child.len > 0 and child[0].kind == nkIdentDefs:
          let discNode = child[0]
          for k in 0 ..< discNode.len - 2:
            let fieldNode = discNode[k]
            if fieldNode.kind == nkEmpty: continue
            let fieldName = nodeName(fieldNode)
            if fieldName.len > 0:
              addTag(tags, file, int(discNode.info.line), fieldName, tkVar,
                     signature = ": " & $discNode[^2],
                     docComment = extractDocComment(discNode))
        for b in 1 ..< child.len:
          collectFields(child[b], file, tags)
      elif child.kind == nkRecList:
        collectFields(child, file, tags)
  of nkOfBranch, nkElse:
    if body.len > 0:
      collectFields(body[body.len - 1], file, tags)
  else:
    discard

proc collectTagsFromAst(n: PNode, file: string, tags: var seq[Tag],
    includePrivate: bool) =
  ## Walks the AST and collects tags for declarations we care about.
  case n.kind
  of nkCommentStmt:
    discard
  of nkProcDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkProc, buildSignature(n), extractDocComment(n))
  of nkFuncDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkFunc, buildSignature(n), extractDocComment(n))
  of nkMethodDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkMethod, buildSignature(n), extractDocComment(n))
  of nkIteratorDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkIterator, buildSignature(n), extractDocComment(n))
  of nkMacroDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkMacro, buildSignature(n), extractDocComment(n))
  of nkTemplateDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkTemplate, buildSignature(n), extractDocComment(n))
  of nkConverterDef:
    if includePrivate or isExportedName(n[namePos]):
      let name = nodeName(n[namePos])
      addTag(tags, file, int(n.info.line), name, tkConverter, buildSignature(n), extractDocComment(n))
  of nkTypeDef:
    if n.len > 0:
      let nameNode = n[0]
      let name = nodeName(nameNode)
      if name.len > 0 and (includePrivate or isExportedName(nameNode)):
        addTag(tags, file, int(n.info.line), name, tkType, docComment = extractDocComment(n))
      # Index object/record fields and enum members
      if n.len > 2:
        let typeBody = n[2]
        if typeBody.kind == nkEnumTy:
          for field in typeBody:
            if field.kind == nkEmpty: continue
            let fieldName = if field.kind == nkEnumFieldDef and field.len > 0:
                                nodeName(field[0])
                              else:
                                nodeName(field)
            if fieldName.len > 0:
              addTag(tags, file, int(field.info.line), fieldName, tkConst,
                     docComment = extractDocComment(field))
        else:
          collectFields(typeBody, file, tags)
  of nkTypeSection, nkVarSection, nkLetSection, nkConstSection:
    for i in 0 ..< n.len:
      if n[i].kind == nkCommentStmt:
        continue
      let def = n[i]
      if def.kind == nkTypeDef:
        collectTagsFromAst(def, file, tags, includePrivate)
        continue
      let nameNode = def[0]
      if includePrivate or isExportedName(nameNode):
        let name = nodeName(nameNode)
        let kindOffset = ord(n.kind) - ord(nkTypeSection)
        let symKind = TagKind(ord(tkType) + kindOffset)
        addTag(tags, file, int(def.info.line), name, symKind, docComment = extractDocComment(def))
  of nkStmtList:
    for i in 0 ..< n.len:
      collectTagsFromAst(n[i], file, tags, includePrivate)
  of nkWhenStmt:
    # Follow the first branch only, like docgen.generateTags.
    if n.len > 0 and n[0].len > 0:
      collectTagsFromAst(lastSon(n[0]), file, tags, includePrivate)
  else:
    discard

proc parseNimFile(conf: ConfigRef, cache: IdentCache, file: string): PNode =
  let abs = AbsoluteFile(absolutePath(file))
  let idx = fileInfoIdx(conf, abs)
  result = syntaxes.parseFile(idx, cache, conf)

proc collectTagsForFile*(conf: ConfigRef, cache: IdentCache, file: string,
    includePrivate = false): seq[Tag] =
  try:
    let ast = parseNimFile(conf, cache, file)
    if ast.isNil:
      return
    collectTagsFromAst(ast, file, result, includePrivate)
  except CatchableError:
    discard

proc moduleNameFromPath(path: string): string =
  ## Derive the Nim module name from a file path by taking the last
  ## path component without its extension.
  let (_, namePart, _) = splitFile(path)
  result = namePart

proc isExcludedPath(path: string, excludes: openArray[string]): bool =
  ## Returns true if `path` should be excluded based on the
  ## user-provided exclude patterns.
  ##
  ## We keep the semantics intentionally simple and ctags-like:
  ## any pattern that appears as a substring of the normalized
  ## (DirSep -> '/') path will exclude the file.
  var normalized = path.replace(DirSep, '/')
  for pat in excludes:
    if pat.len == 0:
      continue
    let normPat = pat.replace(DirSep, '/')
    if normalized.contains(normPat):
      return true

proc sanitizeTagFieldValue(s: string): string =
  ## Normalize a tag field value so that it does not contain any
  ## embedded newlines or tab characters, which would otherwise
  ## break the ctags line-oriented format.
  var lastWasSpace = false
  for ch in s:
    if ch in ['\n', '\r', '\t']:
      if not lastWasSpace:
        result.add ' '
        lastWasSpace = true
    else:
      result.add ch
      lastWasSpace = (ch == ' ')

proc collectTagsStandalone(file: string, includePrivate: bool, projectDir: string): seq[Tag] {.gcsafe.} =
  ## Parse a single file in a standalone context so it can run in parallel.
  {.gcsafe.}:
    var conf = newConfigRef()
    conf.errorMax = high(int)
    conf.projectPath = AbsoluteDir(projectDir)
    conf.setNote(warnLongLiterals, false)
    conf.setNote(warnInconsistentSpacing, false)
    var cache = newIdentCache()
    result = collectTagsForFile(conf, cache, file, includePrivate)

proc generateCtagsForDir*(
    roots: openArray[string],
    excludes: openArray[string],
    baseDir = "",
    includePrivate = false,
    tagRelative = false,
    modulesOnly = false
): seq[Tag] =

  ## Generate a universal-ctags compatible tags file for all Nim
  ## modules found under one or more `roots` (searched recursively),
  ## optionally skipping files whose paths match any of the
  ## `excludes` patterns.
  if roots.len == 0:
    return

  let firstRootAbs = absolutePath(roots[0])
  let projectDir =
    if dirExists(firstRootAbs):
      firstRootAbs
    elif fileExists(firstRootAbs):
      parentDir(firstRootAbs)
    else:
      getCurrentDir()

  let effectiveBaseDir = if baseDir.len == 0: getCurrentDir() else: baseDir

  var tags: seq[Tag] = @[]
  var tasks: seq[FlowVar[seq[Tag]]] = @[]

  for root in roots:
    let absRoot = absolutePath(root)

    if dirExists(absRoot):
      for path in walkDirRec(absRoot):
        if not path.endsWith(".nim"):
          continue

        let relPath =
          try:
            relativePath(path, absRoot)
          except OSError:
            path

        if isExcludedPath(relPath, excludes):
          continue

        let moduleName = moduleNameFromPath(path)
        addTag(tags, path, 1, moduleName, tkModule)
        if not modulesOnly:
          tasks.add spawn collectTagsStandalone(path, includePrivate, projectDir)
    elif fileExists(absRoot):
      # Allow roots to be explicit Nim files in addition to
      # directories; in that case, process just the file itself.
      if not absRoot.endsWith(".nim"):
        continue

      let relPath =
        try:
          relativePath(absRoot, parentDir(absRoot))
        except OSError:
          absRoot

      if isExcludedPath(relPath, excludes):
        continue

      let moduleName = moduleNameFromPath(absRoot)
      addTag(tags, absRoot, 1, moduleName, tkModule)
      if not modulesOnly:
        tasks.add spawn collectTagsStandalone(absRoot, includePrivate, projectDir)

  for t in tasks:
    tags.add(^t)

  if tagRelative:
    for tag in tags.mitems:
      try:
        tag.file = relativePath(tag.file, effectiveBaseDir)
      except OSError:
        # Keep absolute path if relative cannot be constructed
        discard

  result = tags

proc `$`*(tags: seq[Tag]): string =
  # Sort tags by name, then file, then line, as expected by ctags
  # when reporting a sorted file.
  var tags = tags
  tags.sort(proc (a, b: Tag): int =
    result = cmp(a.name, b.name)
    if result == 0:
      result = cmp(a.file, b.file)
    if result == 0:
      result = cmp(a.line, b.line)
  )

  # Header lines for extended ctags format
  result.add "!_TAG_FILE_FORMAT\t2\t/extended format/\n"
  result.add "!_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted, 2=foldcase/\n"
  result.add "!_TAG_PROGRAM_NAME\tntagger\t//\n"
  result.add "!_TAG_PROGRAM_VERSION\t0.1\t//\n"

  for t in tags:
    var line =
      t.name & "\t" &
      t.file & "\t" &
      $t.line & ";\"\t" &
      "kind:" & tagKindName(t.kind) & "\t" &
      "line:" & $t.line & "\t"

    if t.signature.len > 0:
      line.add "signature:" & sanitizeTagFieldValue(t.signature) & "\t"

    line.add "language:Nim\n"
    result.add line

proc queryNimSettingSeq(setting: string): seq[string] =
  ## Invoke the Nim compiler to query a setting sequence such as
  ## `searchPaths` or `nimblePaths`, returning the list of paths.
  let evalCode =
    "import std/compilesettings; for x in querySettingSeq(" &
      setting & "): echo x"
  try:
    let output = execProcess("nim",
                             args = ["--verbosity:0", "--warnings:off", "--hints:off", "--eval:" & evalCode],
                             options = {poStdErrToStdOut, poUsePath})
    for line in output.splitLines:
      let trimmed = line.strip()
      if trimmed.len > 0:
        result.add trimmed
  except CatchableError:
    # If Nim is not available or the query fails, just return an
    # empty list and continue without the extra paths.
    discard

proc queryNimSetting(setting: string): string =
  ## Invoke the Nim compiler to query a single-value setting such as
  ## `libpath`, returning the value as a string.
  let evalCode =
    "import std/compilesettings; echo querySetting(" & setting & ")"
  try:
    let output = execProcess("nim",
                             args = ["--verbosity:0", "--warnings:off", "--hints:off", "--eval:" & evalCode],
                             options = {poStdErrToStdOut, poUsePath})
    result = output.strip()
  except CatchableError:
    discard

proc addRootIfDir(roots: var seq[string], path: string) =
  ## Add `path` to `roots` if it is a directory and not already
  ## present in the list. Paths are normalized to absolute form
  ## before deduplication.
  let p = path.strip()
  if p.len == 0 or not dirExists(p):
    return
  let absP = absolutePath(p)
  for existing in roots:
    if absolutePath(existing) == absP:
      return
  roots.add(absP)

proc nimCfgPaths*(projectDir: string): seq[string] =
  ## Read `nim.cfg` and `config.nims` from `projectDir` and extract
  ## `--path:` (or `-p:`) entries, resolving relative paths against
  ## `projectDir`.
  if projectDir.len == 0 or not dirExists(projectDir):
    return
  for configName in ["nim.cfg", "config.nims"]:
    let configPath = projectDir / configName
    if not fileExists(configPath):
      continue
    for line in readFile(configPath).splitLines:
      var trimmed = line.strip()
      if trimmed.startsWith("#"):
        continue
      var pathVal = ""
      if trimmed.startsWith("--path:"):
        pathVal = trimmed[7..^1]
      elif trimmed.startsWith("-p:"):
        pathVal = trimmed[3..^1]
      else:
        continue
      pathVal = pathVal.strip()
      if pathVal.len >= 2 and pathVal[0] == '"' and pathVal[^1] == '"':
        pathVal = pathVal[1..^2]
      if pathVal.len == 0:
        continue
      let resolvedPath = if isAbsolute(pathVal): pathVal else: projectDir / pathVal
      result.addRootIfDir(resolvedPath)

proc nimblePaths*(): seq[string] =
  for p in queryNimSettingSeq("nimblePaths"):
    result.addRootIfDir(p)

proc searchPaths*(): seq[string] =
  for p in queryNimSettingSeq("searchPaths"):
    result.addRootIfDir(p)

proc stdlibPath*(): string =
  ## Query the Nim compiler for the standard library path.
  result = queryNimSetting("libpath")
  if result.len > 0 and not dirExists(result):
    result = ""

proc isStdlibPath*(path: string): bool =
  ## Check whether `path` is a Nim standard library directory by
  ## looking for `system.nim` or the `std` subdirectory.
  let p = path.strip()
  if p.len == 0 or not dirExists(p):
    return false
  return fileExists(p / "system.nim") or dirExists(p / "std")

proc parseNimbleRequires*(nimblePath: string): seq[string] =
  ## Parse a `.nimble` file and extract the package names from
  ## `requires` statements.
  if not fileExists(nimblePath):
    return
  for line in readFile(nimblePath).splitLines:
    let trimmed = line.strip()
    if not trimmed.startsWith("requires"):
      continue
    var i = 8  # skip "requires"
    while i < trimmed.len:
      while i < trimmed.len and trimmed[i] != '"':
        inc i
      if i >= trimmed.len:
        break
      inc i  # skip opening quote
      let start = i
      while i < trimmed.len and trimmed[i] != '"':
        inc i
      if i >= trimmed.len:
        break
      let depSpec = trimmed[start..<i]
      let depName = depSpec.split({' ', '\t'})[0]
      if depName.len > 0:
        result.add(depName)
      inc i  # skip closing quote

proc extractPkgNameFromDir(dirName: string): string =
  ## Extract the package name from a nimble install directory like
  ## "jsony-1.0.0" or "jsony-1.0.0-abcdef12". Everything before the
  ## first version-looking segment (starting with a digit) is the name.
  var parts = dirName.split('-')
  for i in 0 ..< parts.len:
    if parts[i].len > 0 and parts[i][0] in {'0'..'9'}:
      return parts[0..<i].join("-")
  return dirName

proc normalizePkgName(name: string): string =
  ## Normalize a package name for comparison by lowercasing and
  ## converting hyphens to underscores (Nimble treats them as equivalent).
  result = name.toLowerAscii().replace('-', '_')

proc resolveNimbleDep*(pkgName: string, nimblePaths: seq[string]): string =
  ## Find the installation directory of a Nimble package by name.
  if pkgName.len == 0:
    return ""
  let target = normalizePkgName(pkgName)
  for basePath in nimblePaths:
    if not dirExists(basePath):
      continue
    for kind, path in walkDir(basePath):
      if kind == pcDir:
        let dirName = splitFile(path).name
        let extracted = extractPkgNameFromDir(dirName)
        if normalizePkgName(extracted) == target:
          return path
  return ""

proc discoverScanRoots*(projectRoot: string,
    extraPkgPaths: seq[string] = @[]): tuple[
    projectRoots: seq[string],
    stdlibRoots: seq[string],
    depRoots: seq[string]
  ] =
  ## Discover the three scan scopes for a project:
  ## 1. Project source (root + nim.cfg paths)
  ## 2. Nim standard library
  ## 3. Dependencies declared in the project's `.nimble` file
  ##
  ## `extraPkgPaths` can be used to override or supplement the nimble
  ## package paths used for dependency resolution (useful for testing).
  if projectRoot.len > 0 and dirExists(projectRoot):
    result.projectRoots.addRootIfDir(projectRoot)
    for p in nimCfgPaths(projectRoot):
      result.projectRoots.addRootIfDir(p)

  let lib = stdlibPath()
  if lib.len > 0:
    result.stdlibRoots.addRootIfDir(lib)
  else:
    # Fallback: filter searchPaths for stdlib markers
    for pth in searchPaths():
      if isStdlibPath(pth):
        result.stdlibRoots.addRootIfDir(pth)

  if projectRoot.len > 0 and dirExists(projectRoot):
    var nimbleFile = ""
    for kind, path in walkDir(projectRoot):
      if kind == pcFile and path.endsWith(".nimble"):
        nimbleFile = path
        break
    if nimbleFile.len > 0:
      let deps = parseNimbleRequires(nimbleFile)
      let pkgPaths = if extraPkgPaths.len > 0: extraPkgPaths else: nimblePaths()
      for dep in deps:
        if dep.toLowerAscii() == "nim":
          continue
        let depPath = resolveNimbleDep(dep, pkgPaths)
        if depPath.len > 0:
          result.depRoots.addRootIfDir(depPath)

proc main() =
  ## Simple CLI for ntagger.
  ##
  ## Supports a `-f` flag (like ctags/universal-ctags) to control
  ## where the generated tags are written. If `-f` is not provided
  ## or is set to `-`, tags are written to stdout.
  ##
  ## Additionally supports one or more `--exclude`/`-e` options whose
  ## values are simple path substrings; any Nim file whose path (relative
  ## to the search root) contains one of these substrings will be
  ## skipped, similar to ctags' exclude handling.
  ##
  ## The `--auto`/`-a` flag enables an "auto" mode that sets the
  ## default output file to `tags` and also includes tags for Nim
  ## search paths and Nimble package paths discovered via the Nim
  ## compiler's `compilesettings` module.
  ##
  ## The `--private`/`-p` flag controls whether tags are also
  ## generated for private (non-exported) symbols in addition to
  ## exported ones.

  var
    roots: seq[string] = @[]
    outFile = ""
    expectOutFile = false
    expectExclude = false
    autoMode = false
    systemMode = false
    atlasMode = false
    atlasAllMode = false
    includePrivate = false
    depsOnly = false
    tagRelative = false
    systemModules = false
    excludes: seq[string] = @[]

  var parser = initOptParser(commandLineParams())

  for kind, key, val in parser.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      # Special-case a lone '-' that is parsed as a short option with
      # an empty name: treat it as the filename "-" when it follows
      # `-f`.
      if expectOutFile and kind == cmdShortOption and key.len == 0:
        outFile = "-"
        expectOutFile = false
      else:
        case key
        of "f", "output":
          if val.len > 0:
            outFile = val
            expectOutFile = false
          else:
            # Remember that the next argument should be treated as the
            # value for this option (e.g. `-f tags`).
            expectOutFile = true
        of "e", "exclude":
          if val.len > 0:
            excludes.add val
            expectExclude = false
          else:
            # Next argument will be treated as an exclude pattern.
            expectExclude = true
        of "a", "auto":
          autoMode = true
        of "s", "system":
          systemMode = true
        of "M", "system-modules":
          systemModules = true
        of "p", "private":
          includePrivate = true
        of "atlas-all":
          atlasAllMode = true
        of "atlas":
          atlasMode = true
        of "tag-relative":
          if val == "yes":
            tagRelative = true
          elif val == "no":
            tagRelative = false
        else:
          discard
    of cmdArgument:
      if expectOutFile:
        outFile = key
        expectOutFile = false
      elif expectExclude:
        excludes.add key
        expectExclude = false
      else:
        roots.add key
    of cmdEnd:
      discard

  if roots.len == 0:
    roots.add getCurrentDir()
  var
    rootsToScan: seq[string]
    tags: seq[Tag]
    moduleTags: seq[Tag]

  let
    depsDir = "deps"
    baseDir =
      if tagRelative:
        if outFile.len > 0 and outFile != "-":
          parentDir(outFile)
        else:
          getCurrentDir()
      else: ""

  if systemModules:
    var systemRoots: seq[string]
    for pth in searchPaths():
      if pth.isRelativeTo(depsDir): continue
      systemRoots.add(pth)
    moduleTags = generateCtagsForDir(systemRoots, excludes,
                                         baseDir = baseDir,
                                         includePrivate = includePrivate,
                                         tagRelative = tagRelative,
                                         modulesOnly = true)

  if atlasMode or atlasAllMode:
    for pth in searchPaths():
      let name = pth.splitFile().name
      if name.startsWith("_"): continue
      if not systemMode and not pth.isRelativeTo(depsDir):
        continue
      rootsToScan.add(pth)
    let
      baseDir = if tagRelative: depsDir else: ""
      depTags = generateCtagsForDir(rootsToScan, [],
                                    baseDir = baseDir,
                                    includePrivate = includePrivate,
                                    tagRelative = tagRelative)
    writeFile(depsDir/"tags", $(depTags & moduleTags))
    moduleTags.setLen(0)

    rootsToScan.add(roots)
    outFile = "tags"
  else:
    rootsToScan.add(roots)

  if autoMode:
    # Discover the three scan scopes (project, stdlib, deps) from
    # the first root (or current directory) and add them.
    let projectDir = if roots.len > 0: roots[0] else: getCurrentDir()
    let (projRoots, stdRoots, depRoots) = discoverScanRoots(projectDir)
    for r in projRoots:
      rootsToScan.addRootIfDir(r)
    for r in depRoots:
      rootsToScan.addRootIfDir(r)
    for r in stdRoots:
      rootsToScan.addRootIfDir(r)

    # In auto mode, default the output file to `tags` unless the
    # user has explicitly provided a different `-f`/`--output`.
    if outFile.len == 0:
      outFile = "tags"

  if systemMode:
    for pth in searchPaths():
      if pth.isRelativeTo(depsDir): continue
      rootsToScan.add(pth)
  
  
  tags.add generateCtagsForDir(rootsToScan, excludes,
                               baseDir = baseDir,
                               includePrivate = includePrivate,
                               tagRelative = tagRelative)

  if outFile.len == 0 or outFile == "-":
    stdout.write($(tags & moduleTags))
  else:
    writeFile(outFile, $tags)

when isMainModule:
  main()
