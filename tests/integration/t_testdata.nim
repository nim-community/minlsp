discard """
  exitcode: 0
"""

import std/[os, strutils]
import minlsp
import minlsp/ntagger
import minlsp/logger

# Suppress log output during tests
quietMode = true

const testdataDir = currentSourcePath.parentDir.parentDir / "testdata"

block simple_project_tag_generation:
  let projectDir = testdataDir / "simple_project" / "src"
  let lsp = initMinLSP()
  
  # Generate tags for all files in project
  let utilsFile = projectDir / "utils.nim"
  let tags = lsp.generateCtagsForFile(utilsFile)
  
  # Check that we found expected symbols
  var foundGreet = false
  var foundAdd = false
  var foundPerson = false
  
  for tag in tags:
    case tag.name
    of "greet": foundGreet = true
    of "add": foundAdd = true
    of "Person": foundPerson = true
    else: discard
  
  doAssert foundGreet, "Should find 'greet' proc"
  doAssert foundAdd, "Should find 'add' proc"
  doAssert foundPerson, "Should find 'Person' type"

block multi_module_cross_file:
  let srcDir = testdataDir / "multi_module" / "src"
  let modelsFile = srcDir / "models.nim"
  let servicesFile = srcDir / "services.nim"
  
  let lsp = initMinLSP()
  
  # Generate tags for both files
  let modelsTags = lsp.generateCtagsForFile(modelsFile)
  let servicesTags = lsp.generateCtagsForFile(servicesFile)
  
  # Check models
  var foundUser = false
  var foundPost = false
  for tag in modelsTags:
    if tag.name == "User": foundUser = true
    if tag.name == "Post": foundPost = true
  
  doAssert foundUser
  doAssert foundPost
  
  # Check services
  var foundGetUser = false
  for tag in servicesTags:
    if tag.name == "getUserById":
      foundGetUser = true
      doAssert tag.signature.contains("Option")
  
  doAssert foundGetUser

block generic_types_signatures:
  let containersFile = testdataDir / "generic_types" / "src" / "containers.nim"
  
  let lsp = initMinLSP()
  let tags = lsp.generateCtagsForFile(containersFile)
  
  # Check generic proc signatures
  var foundNewBox = false
  var foundGetValue = false
  
  for tag in tags:
    case tag.name
    of "newBox":
      foundNewBox = true
      doAssert tag.signature.contains("T"), "Generic signature should contain T"
    of "getValue":
      foundGetValue = true
      doAssert tag.signature.contains("Box")
    else: discard
  
  doAssert foundNewBox
  doAssert foundGetValue

block workspace_scanning:
  let projectDir = testdataDir / "simple_project"
  let lsp = initMinLSP()
  
  # Simulate scanning workspace (like initialize would do)
  let srcDir = projectDir / "src"
  let files = @[srcDir / "utils.nim", srcDir / "main.nim"]
  
  var totalTags = 0
  for file in files:
    let tags = lsp.generateCtagsForFile(file)
    totalTags += tags.len
  
  doAssert totalTags > 0, "Should find tags in workspace files"

# Tests pass silently
