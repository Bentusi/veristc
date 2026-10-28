"""LSP server for VeriIDE ST language."""

import subprocess
import json
from pathlib import Path
from typing import Optional

from pygls.server import LanguageServer
from pygls.lsp import types
from pygls.lsp.methods import (
    TEXT_DOCUMENT_DID_OPEN,
    TEXT_DOCUMENT_DID_CHANGE,
    TEXT_DOCUMENT_DID_SAVE,
    TEXT_DOCUMENT_HOVER,
)

from ..backend.build.service import build_project, parse_ndjson_diagnostics
from ..backend.project.service import open_project


class VeriIDELanguageServer(LanguageServer):
    """VeriIDE Language Server for ST."""

    def __init__(self):
        super().__init__("veri-ide-lsp", "v0.1")
        self.project_path: Optional[Path] = None
        self._setup_handlers()

    def _setup_handlers(self):
        """Setup LSP method handlers."""
        
        @self.feature(TEXT_DOCUMENT_DID_OPEN)
        def did_open(params: types.DidOpenTextDocumentParams):
            """Handle document open."""
            self._validate_document(params.text_document.uri, params.text_document.text)

        @self.feature(TEXT_DOCUMENT_DID_CHANGE)
        def did_change(params: types.DidChangeTextDocumentParams):
            """Handle document change."""
            if params.content_changes:
                text = params.content_changes[-1].text
                self._validate_document(params.text_document.uri, text)

        @self.feature(TEXT_DOCUMENT_DID_SAVE)
        def did_save(params: types.DidSaveTextDocumentParams):
            """Handle document save."""
            # Re-validate on save
            doc = self.workspace.get_document(params.text_document.uri)
            if doc:
                self._validate_document(params.text_document.uri, doc.source)

        @self.feature(TEXT_DOCUMENT_HOVER)
        def hover(params: types.HoverParams):
            """Handle hover request."""
            return self._get_hover_info(
                params.text_document.uri,
                params.position.line,
                params.position.character
            )

    def _validate_document(self, uri: str, text: str):
        """Validate document and publish diagnostics."""
        # For now, do basic syntax checking
        # In production, this would call build_project
        diagnostics = []
        
        # Simple validation: check for PROGRAM/END_PROGRAM balance
        program_count = text.count("PROGRAM")
        end_program_count = text.count("END_PROGRAM")
        
        if program_count != end_program_count:
            diagnostics.append(types.Diagnostic(
                range=types.Range(
                    start=types.Position(line=0, character=0),
                    end=types.Position(line=0, character=10)
                ),
                message=f"Unbalanced PROGRAM/END_PROGRAM ({program_count} vs {end_program_count})",
                severity=types.DiagnosticSeverity.Error,
                source="veri-ide"
            ))
        
        # Publish diagnostics
        self.publish_diagnostics(uri, diagnostics)

    def _get_hover_info(self, uri: str, line: int, character: int) -> Optional[types.Hover]:
        """Get hover information for a symbol."""
        # Get the word at the cursor position
        doc = self.workspace.get_document(uri)
        if not doc:
            return None
        
        lines = doc.source.split('\n')
        if line >= len(lines):
            return None
        
        current_line = lines[line]
        
        # Extract word at position
        word = self._get_word_at_position(current_line, character)
        if not word:
            return None
        
        # Try to find symbol info from build artifacts
        # This would normally query the symbol table from section 7
        # For now, return basic info
        if word in ("PROGRAM", "FUNCTION", "FUNCTION_BLOCK", "VAR", "END_VAR"):
            return types.Hover(
                contents=types.MarkupContent(
                    kind=types.MarkupKind.Markdown,
                    value=f"**{word}**\n\nST keyword"
                )
            )
        
        # Check if it's a type
        types_list = ["BOOL", "INT", "DINT", "REAL", "STRING", "TIME"]
        if word in types_list:
            return types.Hover(
                contents=types.MarkupContent(
                    kind=types.MarkupKind.Markdown,
                    value=f"**{word}**\n\nST data type"
                )
            )
        
        return None

    def _get_word_at_position(self, line: str, position: int) -> Optional[str]:
        """Extract word at given position in line."""
        if position >= len(line):
            return None
        
        # Find word boundaries
        start = position
        while start > 0 and (line[start - 1].isalnum() or line[start - 1] == '_'):
            start -= 1
        
        end = position
        while end < len(line) and (line[end].isalnum() or line[end] == '_'):
            end += 1
        
        if start == end:
            return None
        
        return line[start:end]


def run_server():
    """Run the LSP server."""
    server = VeriIDELanguageServer()
    server.start_io()


if __name__ == "__main__":
    run_server()
