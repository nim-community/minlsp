# Package

version       = "0.1.0"
author        = "bung87"
description   = "A lightweight LSP server for Nim based on ctags using ntagger"
license       = "MIT"
srcDir        = "src"
bin           = @["minlsp"]

# Dependencies

requires "nim >= 2.0.16"

# Test task
task test, "Run testament tests":
  exec "testament all"
