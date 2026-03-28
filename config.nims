import std/os

const explicitSourcePath {.strdefine.} = getCurrentCompilerExe().parentDir.parentDir
switch "path", explicitSourcePath

# Add project source path for tests
switch "path", projectDir() / "src"
