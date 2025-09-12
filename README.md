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

## Notes

- Requires pylsp to be attached to the buffer; no Treesitter is required.
- Errors are reported via `vim.notify` under the title `py-autoimport`.
