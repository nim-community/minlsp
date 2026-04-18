discard """
  exitcode: 0
"""

import std/[os, asyncdispatch, tables, strutils]
import minlsp
import minlsp/ntagger
import minlsp/logger

# Suppress log output during tests
quietMode = true

block search_paths_returns_existing_dirs:
  let paths = searchPaths()
  doAssert paths.len > 0, "searchPaths should return at least one directory"
  for p in paths:
    doAssert dirExists(p), "searchPaths entry should exist: " & p

block stdlib_tags_available_after_scan:
  let lsp = initMinLSP()
  let testDir = getTempDir() / "minlsp_stdlib_test"
  createDir(testDir)
  let testFile = testDir / "main.nim"
  writeFile(testFile, "proc main() = echo \"hi\"\n")

  lsp.rootPath = testDir
  waitFor scanProjectAsync(lsp)

  # Should have scanned both the workspace and stdlib
  doAssert lsp.ctagsCache.len > 0

  # Verify that stdlib files (outside testDir) were indexed
  var foundStdlibFile = false
  for path in lsp.ctagsCache.keys:
    if not path.startsWith(testDir):
      foundStdlibFile = true
      break
  doAssert foundStdlibFile, "stdblib files should be in ctagsCache after scanProjectAsync"

  removeDir(testDir)

block workspace_symbols_finds_stdlib_symbols:
  let lsp = initMinLSP()
  let testDir = getTempDir() / "minlsp_stdlib_test2"
  createDir(testDir)
  let testFile = testDir / "main.nim"
  writeFile(testFile, "proc main() = discard\n")

  lsp.rootPath = testDir
  waitFor scanProjectAsync(lsp)

  # Look up a well-known stdlib symbol
  let symbols = lsp.getWorkspaceSymbols("parseInt")
  doAssert symbols.len > 0, "parseInt from strutils should be found in workspace symbols"

  removeDir(testDir)

block completions_include_stdlib_symbols:
  let lsp = initMinLSP()
  let testDir = getTempDir() / "minlsp_stdlib_test3"
  createDir(testDir)
  let testFile = testDir / "main.nim"
  let content = "proc main() =\n  parse"
  writeFile(testFile, content)

  lsp.rootPath = testDir
  waitFor scanProjectAsync(lsp)

  lsp.updateFile("file://" & testFile, content)

  # Cursor at end of "parse" on line 1, col 6 -> word = "parse"
  let completions = lsp.getCompletions("file://" & testFile, 1, 6)
  var foundParseInt = false
  for c in completions:
    if c.label == "parseInt":
      foundParseInt = true
      break
  doAssert foundParseInt, "parseInt should appear in completions after stdlib scan"

  removeDir(testDir)
