# VeriIDE Frontend

Web-based ST (Structured Text) editor with syntax highlighting and diagnostics.

## Features

- **Monaco Editor**: VS Code's editor component with full ST language support
- **Syntax Highlighting**: TextMate grammar for ST keywords, types, operators, comments
- **Diagnostics**: Real-time validation with error markers
- **Build Integration**: Connects to backend build service for compilation

## Quick Start

```bash
# Serve the editor locally
cd veri-ide/frontend/public
python3 -m http.server 8080

# Open in browser
# http://localhost:8080
```

## Architecture

- `public/index.html` - Main editor page
- `public/editor.js` - Monaco Editor integration
- `src/st-language.tmLanguage.json` - ST syntax grammar

## ST Language Support

The editor supports IEC 61131-3 Structured Text with:

- **Keywords**: PROGRAM, FUNCTION, FUNCTION_BLOCK, VAR, IF, FOR, WHILE, etc.
- **Types**: BOOL, INT, DINT, REAL, STRING, TIME, etc.
- **Operators**: :=, =, <>, <, >, <=, >=, +, -, *, /, MOD, AND, OR, XOR, NOT
- **Comments**: (* ... *) and // ...
- **Strings**: "..." and '...'

## Future Enhancements

- **LSP Integration**: Full Language Server Protocol support for advanced features
- **Auto-completion**: Context-aware code completion
- **Hover Info**: Variable types and addresses from symbol table
- **Go to Definition**: Navigate to variable/function declarations
- **Live Build**: Automatic compilation on save
