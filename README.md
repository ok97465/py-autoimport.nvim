# py-autoimport.nvim

Auto-import undefined Python symbols from your workspace. Neovim 0.11+ only.

## Overview

- Detects undefined names via pylsp (pyflakes F821) diagnostics in the current buffer.
- First tries project JSON maps (`autoimport_for_python.json`, `autoimport_for_project.json`) to import known aliases/modules (e.g., `np` -> `import numpy as np`). If not found, searches the workspace with ripgrep for top-level definitions and inserts an appropriate `from pkg.mod import Name`.
- Respects isort section headers when present (`pyproject.toml`, `.isort.cfg`, `setup.cfg`, `tox.ini`).
- Falls back to default headers (including `# %% Import`).

## Requirements

- Neovim 0.11+
- python-lsp-server (`pylsp`) running for the buffer
- ripgrep (`rg`) in your `PATH`
- Optional: `vim-isort` (or any command that formats/import-sorts), default command: `Isort`

## Installation (example)

```vim
Plug 'fisadev/vim-isort'         " optional, to sort/dedupe imports
Plug 'ok97465/py-autoimport.nvim'
```

## Setup

```lua
require('py_autoimport').setup({
  search = {
    globs_include = { '*.py' },
    globs_exclude = { '.venv/**', 'venv/**', '__pycache__/**', 'build/**', 'dist/**' },
    include_variables = true,                -- also search variables
    include_annotations_without_value = false,
  },
  insert = {
    docstring_scan_lines = 50,
    import_scan_lines = 300,
    isort_command = 'Isort',                 -- set to nil to disable
    add_trailing_blank_line = true,
    header_markers = {
      '# %% Import',
      '# Standard library imports',
      '# Local imports',
      '# Third party imports',
    },
  },
  path = { collapse_dunder_init = true },    -- pkg/__init__.py -> pkg
})
```

### pylsp Setup (nvim-lspconfig)

Enable pylsp with pyflakes diagnostics so this plugin can read F821 undefined-name reports.

```lua
-- Minimal pylsp configuration with pyflakes enabled
require('lspconfig').pylsp.setup({
  settings = {
    pylsp = {
      plugins = {
        pyflakes = { enabled = true },  -- required for F821 undefined-name
        pycodestyle = { enabled = false }, -- optional: reduce noise
        mccabe = { enabled = false },      -- optional
        pylint = { enabled = false },      -- optional
        autopep8 = { enabled = false },    -- optional
        yapf = { enabled = false },        -- optional
      },
    },
  },
})
```

## Usage

```
:PyAutoImport
```

- Scans the current buffer for undefined names reported by pylsp, searches the workspace, inserts imports, then runs `Isort` if configured.
- JSON maps take precedence; if both JSONs are missing or no match exists, workspace search is used. When both JSONs are present, their union is used (project overrides per-key).
- If multiple matches exist, the first match is used (closest to project root). Improvements like interactive selection can be added later.

## Create autoimport_for_python.json

You can define project-specific import rules with a JSON file placed in your project root (the Neovim working directory).

- Recognized files: `autoimport_for_python.json`, `autoimport_for_project.json`
- Merge and precedence: both are optional; when both exist, their union is used and `autoimport_for_project.json` overrides per symbol. If neither exists, the plugin’s default map at `data/autoimport_for_python.json` is used.

Structure of the JSON:

- alias: map of alias to module string
  - Generates `import <module>` when alias == module
  - Generates `import <module> as <alias>` when alias != module
- module: map of module path to symbols to import
  - Value can be a single string or a list of strings
  - Generates `from <module> import <Name>` for each symbol

Example `autoimport_for_python.json`:

```json
{
  "alias": {
    "np": "numpy",
    "plt": "matplotlib.pyplot",
    "os": "os"            
  },
  "module": {
    "numpy.linalg": ["norm", "inv"],
    "pathlib": "Path",
    "pandas": ["DataFrame", "Series"]
  }
}
```

Notes:

- The file must be valid JSON (no comments). UTF-8 is recommended.
- When multiple candidates exist for the same symbol, the first one in the resolved map is used.
- Run `:PyAutoImport` to apply your rules; JSON mappings are applied before workspace search.

## Notes

- Requires pylsp to be attached to the buffer; no Treesitter is required.
- Errors are reported via `vim.notify` under the title `py-autoimport`.
