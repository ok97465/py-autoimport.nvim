-- init: main entry for py-autoimport.nvim
-- Detect undefined names via Ruff diagnostics and auto-insert imports

local util = require('py_autoimport.util')

local M = {}

function M.setup(opts)
  util.setup(opts or {})
end

-- Ruff diagnostics are treated as the single source of truth for undefined symbols

-- Extract symbol name fragments from Ruff diagnostic messages
local function extract_name_from_message(msg)
  if type(msg) ~= 'string' or msg == '' then
    return nil
  end
  local patterns = {
    "[Uu]ndefined name [`'\"]([%w_%.]+)[`'\"]",
    "[Uu]ndefined variable [`'\"]([%w_%.]+)[`'\"]",
    "[Nn]ame [`'\"]([%w_%.]+)[`'\"] is not defined",
    "[Nn]ame [`'\"]([%w_%.]+)[`'\"] is undefined",
    "[Uu]ndefined name:?[%s]+([%w_%.]+)",
    "[Uu]ndefined variable:?[%s]+([%w_%.]+)",
  }
  for _, pattern in ipairs(patterns) do
    local match = msg:match(pattern)
    if match then
      return match
    end
  end
  local plain = msg:match("^([%w_%.]+) is not defined")
  if plain then
    return plain
  end
  return nil
end

-- Extract undefined names from Ruff diagnostics
local function undefined_from_ruff()
  local diags = vim.diagnostic.get(0)
  local names, seen = {}, {}
  for _, d in ipairs(diags or {}) do
    local src = type(d.source) == 'string' and d.source or ''
    local code = d.code
    if not code and d.user_data and d.user_data.lsp then
      code = d.user_data.lsp.code
    end
    code = tostring(code or '')
    local code_upper = code:upper()
    local msg = (d.message or '')
    local src_l = src:lower()
    local is_ruff = src_l:find('ruff', 1, true) ~= nil or code_upper:match('^[FE]%d+$') ~= nil
    local lower = msg:lower()
    local is_undefined = (code_upper == 'F821')
      or lower:find('undefined name', 1, true)
      or lower:find('undefined variable', 1, true)
      or lower:find('is not defined', 1, true)
    if is_ruff and is_undefined then
      -- Extract the symbol name from the Ruff diagnostic text
      local name = extract_name_from_message(msg)
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
  table.insert(parts, '^def[[:space:]]+' .. vim.pesc(symbol) .. '[[:space:]]*[(]')
  -- class Symbol( or class Symbol:
  table.insert(parts, '^class[[:space:]]+' .. vim.pesc(symbol) .. '[[:space:]:(]')
  if cfg.search.include_variables then
    local base = ('^%s[[:space:]]*'):format(vim.pesc(symbol))
    if cfg.search.include_annotations_without_value then
      table.insert(parts, base .. ':')
    end
    table.insert(parts, base .. '(:[^=]+)?[[:space:]]*=')
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

  -- Collect undefined names from Ruff diagnostics
  local undefined = undefined_from_ruff()

  if #undefined == 0 then
    -- still allow running isort if configured
    local cmd = util.get_config().insert.isort_command
    if cmd and #cmd > 0 then pcall(vim.api.nvim_command, cmd) end
    util.info('No undefined names from Ruff diagnostics')
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
