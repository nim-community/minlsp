# minlsp

[![Test](https://github.com/nim-community/minlsp/actions/workflows/test.yml/badge.svg)](https://github.com/nim-community/minlsp/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Nim](https://img.shields.io/badge/nim-%3E%3D2.0.16-orange.svg)](https://nim-lang.org)

A lightweight Language Server Protocol (LSP) implementation for Nim, powered by ctags via [ntagger](https://github.com/j-crag/ntagger).

## Overview

minlsp provides IDE-like features for Nim code by leveraging ctags for fast and accurate symbol indexing. Unlike traditional LSP servers that require complex AST analysis, minlsp uses a tag-based approach for quick symbol lookup and navigation.

## Features

### Implemented LSP Features

- **Lifecycle Management**
  - Initialize/Shutdown/Exit

- **Text Document Synchronization**
  - Open/Close/Change notifications

- **Language Features**
  - ✅ Code Completion - Get completion suggestions based on ctags
  - ✅ Hover Information - View symbol documentation on hover
  - ✅ Go to Definition - Navigate to symbol definitions
  - ✅ Find References - Find all references to a symbol
  - ✅ Signature Help - Show function signatures while typing
  - ✅ Document Symbols - List all symbols in a document

### Supported Symbol Types

- Procedures (`proc`)
- Functions (`func`)
- Methods (`method`)
- Iterators (`iterator`)
- Converters (`converter`)
- Macros (`macro`)
- Templates (`template`)
- Types (`type`)
- Variables (`var`)
- Constants (`let`, `const`)
- Modules (`module`)

## Requirements

- Nim >= 2.0.16
- compiler package (comes with Nim)

## Installation

### From Source

```bash
git clone <repository-url>
cd minlsp
nimble build
```

### Using Nimble

```bash
nimble install minlsp
```

## Usage

### Starting the Server

```bash
# Start the LSP server
./minlsp

# Or with nimble
nimble run minlsp
```

### Log File

minlsp writes debug logs to `~/.minlsp/minlsp.log` in your home directory. This is useful for troubleshooting issues with the language server.

## Architecture

minlsp consists of:

1. **LSP Protocol Handler** - Handles JSON-RPC communication
2. **ntagger Integration** - Uses ntagger for parsing Nim files and generating ctags
3. **Symbol Cache** - Caches tags for fast lookups
4. **File Manager** - Tracks open files and their contents

## How It Works

1. When a file is opened, minlsp uses ntagger to parse the Nim AST and extract symbols
2. Symbols are cached for fast access
3. LSP requests (completion, hover, definition, references, signature help) query the cached tags
4. When files change, the cache is updated incrementally

## Development

### Running Tests

```bash
# Run integration tests
nim c -r tests/run_tests.nim

# Run unit tests
nim c -r tests/test_lsp.nim
nim c -r tests/test_protocol.nim
```

### Project Structure

```
minlsp/
├── src/
│   ├── minlsp.nim      # Main LSP server implementation
│   └── ntagger.nim     # ntagger library integration
├── tests/
│   ├── test_lsp.nim    # Core LSP tests
│   ├── test_protocol.nim # Protocol tests
│   └── run_tests.nim   # Test runner
├── minlsp.nimble       # Nimble configuration
└── README.md           # This file
```

## Comparison with Other Nim LSP Servers

| Feature | minlsp | nimlsp | nimlangserver |
|---------|--------|--------|---------------|
| Completion | ✅ | ✅ | ✅ |
| Hover | ✅ | ✅ | ✅ |
| Go to Definition | ✅ | ✅ | ✅ |
| Document Symbols | ✅ | ✅ | ✅ |
| Find References | ✅ | ✅ | ✅ |
| Signature Help | ✅ | ✅ | ✅ |
| Rename | ❌ | ❌ | ✅ |
| Formatting | ❌ | ✅ | ✅ |
| Memory Usage | Low | Medium | High |
| Startup Time | Fast | Medium | Slow |

minlsp trades some advanced features for speed and simplicity.

## Limitations

- No semantic analysis (type checking, error reporting)
- Find References only searches currently open files (not full workspace)
- No code formatting
- No refactoring support (rename, extract method, etc.)

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

MIT License - see LICENSE file for details

## Acknowledgments

- [ntagger](https://github.com/j-crag/ntagger) - The ctags generator for Nim
- [nimlsp](https://github.com/PMunch/nimlsp) - Inspiration for this project
- [LSP Specification](https://microsoft.github.io/language-server-protocol/) - LSP protocol reference
