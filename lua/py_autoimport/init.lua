-- init: main entry for py-autoimport.nvim
-- Detect undefined names via pylsp diagnostics and auto-insert imports

local util = require('py_autoimport.util')

local M = {}

function M.setup(opts)
  util.setup(opts or {})
end

-- Heuristic keyword/builtin tables removed: pylsp diagnostics are authoritative

-- Extract undefined names from pylsp/pyflakes diagnostics
local function undefined_from_pylsp()
  -- Ensure pylsp client is available for this buffer
  local has_pylsp = false
  local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
  if get_clients then
    local list = get_clients({ bufnr = 0, name = 'pylsp' }) or {}
    has_pylsp = #list > 0
  end
  if not has_pylsp then
    util.error('pylsp is not attached to this buffer')
    return {}
  end

  local diags = vim.diagnostic.get(0)
  local names, seen = {}, {}
  for _, d in ipairs(diags or {}) do
    local src = (d.source or '')
    local code = tostring(d.code or '')
    local msg = (d.message or '')
    local is_pyflakes = (src == 'pyflakes' or src == 'pylsp' or src == 'pylsp.plugins.pyflakes')
    local lower = msg:lower()
    local is_undefined = (code == 'F821') or lower:find('undefined name', 1, true) or lower:find('is not defined', 1, true)
    if is_pyflakes and is_undefined then
      -- Try to extract the symbol name from the message
      local name = msg:match("undefined name ['\"]([%w_%.]+)['\"]")
                 or msg:match("name ['\"]([%w_%.]+)['\"] is not defined")
                 or msg:match('undefined name ([%w_%.]+)')
                 or msg:match('^([%w_%.]+) is not defined')
      if name and not seen[name] then
        table.insert(names, name)
        seen[name] = true
      end
    end
  end
  table.sort(names)
  return names
end

-- Build ripgrep command to search symbol definitions
local function build_rg_command(symbol)
  local cfg = util.get_config()
  local parts = {}
  -- def symbol(
  table.insert(parts, ('^def\s+%s\s*\('):format(vim.pesc(symbol)))
  -- class Symbol( or class Symbol:
  table.insert(parts, ('^class\s+%s[%s:(]'):format(vim.pesc(symbol)))
  if cfg.search.include_variables then
    local base = ('^%s\s*'):format(vim.pesc(symbol))
    if cfg.search.include_annotations_without_value then
      table.insert(parts, base .. ':')
    end
    table.insert(parts, base .. '(:[^=]+)?%s*=')
  end

  local cli = {}
  -- base vimgrep arguments from Telescope defaults (inline to avoid dependency)
  -- equivalent to: rg --color=never --no-heading --with-filename --line-number --column --smart-case
  vim.list_extend(cli, { 'rg', '--color=never', '--no-heading', '--with-filename', '--line-number', '--column', '--smart-case' })
  for _, g in ipairs(cfg.search.globs_include or {}) do
    table.insert(cli, '--glob'); table.insert(cli, g)
  end
  for _, g in ipairs(cfg.search.globs_exclude or {}) do
    table.insert(cli, '--glob'); table.insert(cli, '!' .. g)
  end
  for _, re in ipairs(parts) do
    table.insert(cli, '-e'); table.insert(cli, re)
  end
  table.insert(cli, '.')
  return cli
end

-- Parse a single ripgrep output line: file:lnum:col:text
local function parse_rg_line(line)
  local filename, lnum, col, text = line:match('^([^:]+):(%d+):(%d+):(.*)$')
  return filename, tonumber(lnum), tonumber(col), text
end

-- Choose a best candidate line (first match for now)
local function pick_candidate(lines)
  if #lines == 0 then return nil end
  return lines[1]
end

local function search_symbol(symbol)
  if vim.fn.executable('rg') ~= 1 then
    util.error('ripgrep (rg) not found in PATH')
    return nil
  end
  local cmd = build_rg_command(symbol)
  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local hits = {}
  for _, line in ipairs(output or {}) do
    local f, l, c, t = parse_rg_line(line)
    if f and l and c and t then table.insert(hits, { file = f, line = l, col = c, text = t }) end
  end
  return pick_candidate(hits)
end

-- Main command: auto-import undefined symbols
function M.auto_import()
  -- Verify filetype
  if vim.bo.filetype ~= 'python' then
    util.warn('Current buffer is not a Python file')
    return
  end

  -- Collect undefined names from pylsp diagnostics
  local undefined = undefined_from_pylsp()

  if #undefined == 0 then
    -- still allow running isort if configured
    local cmd = util.get_config().insert.isort_command
    if cmd and #cmd > 0 then pcall(vim.api.nvim_command, cmd) end
    util.info('No undefined names from pylsp')
    return
  end

  -- 1) Prefer autoimport from JSON maps (working dir first, then plugin defaults)
  local map_json = util.get_autoimport_map() or {}
  local json_lines = {}
  local leftover = {}
  for _, name in ipairs(undefined) do
    local list = map_json[name]
    if type(list) == 'table' and #list > 0 then
      -- pick the first candidate like the original plugin
      table.insert(json_lines, list[1])
    else
      table.insert(leftover, name)
    end
  end

  local did_any = false
  if #json_lines > 0 then
    did_any = util.insert_import_lines(json_lines) or did_any
  end

  -- 2) Fallback: search workspace for remaining symbols
  if #leftover > 0 then
    local mapping = {}
    for _, name in ipairs(leftover) do
      local hit = search_symbol(name)
      if hit and hit.file then
        local path = util.filename2path_rel(hit.file)
        mapping[name] = path
      else
        util.warn(('No definition found for %s'):format(name))
      end
    end
    if not vim.tbl_isempty(mapping) then
      did_any = util.insert_import(mapping) or did_any
    end
  end

  if not did_any then
    util.warn('No imports to insert')
  end
end

return M
