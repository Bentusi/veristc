// VeriIDE ST Editor - Monaco Editor integration

let editor;
let currentDiagnostics = [];

// Initialize Monaco Editor
require.config({ paths: { vs: 'https://cdn.jsdelivr.net/npm/monaco-editor@0.45.0/min/vs' } });

require(['vs/editor/editor.main'], function () {
    // Register ST language
    monaco.languages.register({ id: 'st' });
    
    // Load TextMate grammar
    fetch('src/st-language.tmLanguage.json')
        .then(response => response.json())
        .then(grammar => {
            monaco.languages.setMonarchTokensProvider('st', createMonarchTokenizer(grammar));
        })
        .catch(err => {
            console.warn('Failed to load ST grammar, using fallback:', err);
            monaco.languages.setMonarchTokensProvider('st', createFallbackTokenizer());
        });

    // Create editor instance
    editor = monaco.editor.create(document.getElementById('editor'), {
        value: `PROGRAM main
VAR
    counter : DINT;
    status : BOOL;
END_VAR

counter := counter + 1;
IF counter > 100 THEN
    counter := 0;
    status := TRUE;
END_IF;

END_PROGRAM
`,
        language: 'st',
        theme: 'vs-dark',
        automaticLayout: true,
        minimap: { enabled: true },
        scrollBeyondLastLine: false,
        fontSize: 14,
        lineNumbers: 'on',
        renderWhitespace: 'selection',
    });

    // Setup event listeners
    setupEventListeners();
    
    updateStatus('Ready');
});

// Create Monarch tokenizer from TextMate grammar (simplified)
function createMonarchTokenizer(grammar) {
    return {
        defaultToken: '',
        tokenPostfix: '.st',
        
        keywords: [
            'PROGRAM', 'END_PROGRAM', 'FUNCTION', 'END_FUNCTION', 
            'FUNCTION_BLOCK', 'END_FUNCTION_BLOCK',
            'VAR', 'VAR_INPUT', 'VAR_OUTPUT', 'VAR_IN_OUT', 'VAR_TEMP', 'END_VAR',
            'IF', 'THEN', 'ELSIF', 'ELSE', 'END_IF',
            'CASE', 'OF', 'END_CASE',
            'FOR', 'TO', 'BY', 'DO', 'END_FOR',
            'WHILE', 'END_WHILE',
            'REPEAT', 'UNTIL', 'END_REPEAT',
            'RETURN', 'EXIT',
            'TRUE', 'FALSE'
        ],
        
        typeKeywords: [
            'BOOL', 'BYTE', 'WORD', 'DWORD', 'LWORD',
            'SINT', 'INT', 'DINT', 'LINT',
            'USINT', 'UINT', 'UDINT', 'ULINT',
            'REAL', 'LREAL',
            'TIME', 'DATE', 'TIME_OF_DAY', 'TOD', 'DATE_AND_TIME', 'DT',
            'STRING', 'WSTRING'
        ],
        
        operators: [
            ':=', '=', '<>', '<', '>', '<=', '>=',
            '+', '-', '*', '/', 'MOD',
            'AND', 'OR', 'XOR', 'NOT'
        ],
        
        symbols: /[=><!~?:&|+\-*\/\^%]+/,
        
        tokenizer: {
            root: [
                // Comments
                [/\(\*.*?\*\)/, 'comment'],
                [/\/\/.*$/, 'comment'],
                
                // Strings
                [/"[^"]*"/, 'string'],
                [/'[^']*'/, 'string'],
                
                // Numbers
                [/\d+/, 'number'],
                [/16#[0-9A-Fa-f]+/, 'number.hex'],
                [/2#[01]+/, 'number.binary'],
                
                // Keywords
                [/[a-zA-Z_]\w*/, {
                    cases: {
                        '@keywords': 'keyword',
                        '@typeKeywords': 'type',
                        '@operators': 'operator',
                        '@default': 'identifier'
                    }
                }],
                
                // Operators
                [/@symbols/, {
                    cases: {
                        '@operators': 'operator',
                        '@default': ''
                    }
                }],
                
                // Punctuation
                [/[;,.]/, 'delimiter'],
                [/[()]/, '@brackets'],
            ],
        }
    };
}

// Fallback tokenizer if grammar fails to load
function createFallbackTokenizer() {
    return {
        tokenizer: {
            root: [
                [/\(\*.*?\*\)/, 'comment'],
                [/\/\/.*$/, 'comment'],
                [/"[^"]*"/, 'string'],
                [/'[^']*'/, 'string'],
                [/\d+/, 'number'],
                [/\b(PROGRAM|END_PROGRAM|FUNCTION|END_FUNCTION|VAR|END_VAR|IF|THEN|ELSE|END_IF|FOR|END_FOR|WHILE|END_WHILE)\b/, 'keyword'],
                [/\b(BOOL|INT|DINT|REAL|STRING)\b/, 'type'],
                [/:=/, 'operator'],
                [/[a-zA-Z_]\w*/, 'identifier'],
                [/[;,.]/, 'delimiter'],
            ]
        }
    };
}

function setupEventListeners() {
    // Build button
    document.getElementById('btn-build').addEventListener('click', async () => {
        await buildProject();
    });
    
    // Clear diagnostics button
    document.getElementById('btn-clear').addEventListener('click', () => {
        clearDiagnostics();
    });
    
    // Editor content change
    editor.onDidChangeModelContent(() => {
        updateStatus('Modified');
    });
}

async function buildProject() {
    const btnBuild = document.getElementById('btn-build');
    const buildStatus = document.getElementById('build-status');
    
    btnBuild.disabled = true;
    buildStatus.textContent = 'Building...';
    buildStatus.style.color = '#75beff';
    updateStatus('Building...');
    
    try {
        // Get editor content
        const code = editor.getValue();
        
        // Call build API (mock for now - will integrate with backend later)
        const result = await mockBuild(code);
        
        if (result.success) {
            buildStatus.textContent = '✓ Build successful';
            buildStatus.style.color = '#89d185';
            updateStatus('Build successful');
            clearDiagnostics();
        } else {
            buildStatus.textContent = '✗ Build failed';
            buildStatus.style.color = '#f48771';
            updateStatus('Build failed');
            showDiagnostics(result.diagnostics);
        }
    } catch (error) {
        buildStatus.textContent = '✗ Build error';
        buildStatus.style.color = '#f48771';
        updateStatus('Build error: ' + error.message);
        console.error('Build error:', error);
    } finally {
        btnBuild.disabled = false;
    }
}

// Mock build API (will be replaced with real backend call)
async function mockBuild(code) {
    // Try to call real backend API
    try {
        const response = await fetch('http://127.0.0.1:8000/build', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                code: code,
                project_name: 'editor_temp'
            })
        });
        
        if (response.ok) {
            const result = await response.json();
            return {
                success: result.success,
                diagnostics: result.diagnostics.map(d => ({
                    severity: d.severity,
                    message: d.message,
                    line: d.line || 1,
                    column: d.column || 1
                }))
            };
        }
    } catch (error) {
        console.warn('Backend API not available, using mock build:', error.message);
    }
    
    // Fallback to mock build
    // Simulate network delay
    await new Promise(resolve => setTimeout(resolve, 500));
    
    // Simple validation
    const diagnostics = [];
    
    if (!code.includes('PROGRAM') && !code.includes('FUNCTION')) {
        diagnostics.push({
            severity: 'error',
            message: 'No PROGRAM or FUNCTION declaration found',
            line: 1,
            column: 1
        });
    }
    
    if (code.includes('END_PROGRAM') && !code.includes('PROGRAM')) {
        diagnostics.push({
            severity: 'error',
            message: 'END_PROGRAM without matching PROGRAM',
            line: code.split('\n').findIndex(l => l.includes('END_PROGRAM')) + 1,
            column: 1
        });
    }
    
    return {
        success: diagnostics.length === 0,
        diagnostics: diagnostics
    };
}

function showDiagnostics(diagnostics) {
    const container = document.getElementById('diagnostics');
    container.innerHTML = '';
    
    if (diagnostics.length === 0) {
        const div = document.createElement('div');
        div.style.color = '#89d185';
        div.textContent = 'No diagnostics';
        container.appendChild(div);
        return;
    }
    
    diagnostics.forEach(diag => {
        const div = document.createElement('div');
        div.className = `diagnostic-${diag.severity}`;
        div.textContent = `[${diag.severity.toUpperCase()}] Line ${diag.line}: ${diag.message}`;
        container.appendChild(div);
    });
    
    // Also show in editor
    const model = editor.getModel();
    const markers = diagnostics.map(diag => ({
        severity: diag.severity === 'error' ? monaco.MarkerSeverity.Error :
                  diag.severity === 'warning' ? monaco.MarkerSeverity.Warning :
                  monaco.MarkerSeverity.Info,
        message: diag.message,
        startLineNumber: diag.line,
        startColumn: diag.column || 1,
        endLineNumber: diag.line,
        endColumn: (diag.column || 1) + 10
    }));
    
    monaco.editor.setModelMarkers(model, 'st', markers);
    currentDiagnostics = diagnostics;
}

function clearDiagnostics() {
    const container = document.getElementById('diagnostics');
    container.innerHTML = '';
    const div = document.createElement('div');
    div.style.color = '#89d185';
    div.textContent = 'No diagnostics';
    container.appendChild(div);
    
    const model = editor.getModel();
    monaco.editor.setModelMarkers(model, 'st', []);
    currentDiagnostics = [];
}

function updateStatus(message) {
    document.getElementById('status-left').textContent = message;
}
