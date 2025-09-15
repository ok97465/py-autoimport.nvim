-- util: shared utilities, configuration and import insertion

local M = {}

M.config = {
  search = {
    globs_include = { '*.py' },
    globs_exclude = { '.venv/**', 'venv/**', '__pycache__/**', 'build/**', 'dist/**' },
    include_variables = true,
    include_annotations_without_value = false,
  },
  insert = {
    docstring_scan_lines = 50,
    import_scan_lines = 300,
    isort_command = 'Isort',
    add_trailing_blank_line = true,
    header_markers = {
      '# %% Import',
      '# Standard library imports',
      '# Local imports',
      '# Third party imports',
    },
  },
  path = { collapse_dunder_init = true },
}

local function notify(level, msg)
  local lvl = (vim.log and vim.log.levels and vim.log.levels[level]) or level or 'INFO'
  local header = '[py_autoimport] '
  local body = type(msg) == 'string' and msg or vim.inspect(msg)
  vim.notify(header .. body, lvl, { title = 'py-autoimport' })
end

function M.error(msg) notify('ERROR', msg) end
function M.warn(msg)  notify('WARN', msg)  end
function M.info(msg)  notify('INFO', msg)  end

local function tbl_deep_extend(dst, src)
  return vim.tbl_deep_extend('force', dst or {}, src or {})
end

function M.setup(opts)
  -- Apply user options by deep merging into default config
  -- NOTE: Previous code ignored the merged result, so overrides were not applied.
  if opts and type(opts) == 'table' then
    M.config = tbl_deep_extend(M.config, opts)
  end
end

function M.get_config()
  return M.config
end

-- Resolve this plugin's root directory from this file path
local function plugin_root()
  local src = debug.getinfo(1, 'S').source or ''
  if src:sub(1, 1) == '@' then src = src:sub(2) end
  local dir = vim.fs.dirname(src)
  -- dir -> .../lua/py_autoimport; root is two levels up
  return vim.fs.dirname(vim.fs.dirname(dir))
end

-- Convert file path to python import path relative to cwd
function M.filename2path_rel(filename)
  local cfg = M.config
  local path_rel = filename
  if path_rel:find('.\\', 1, true) or path_rel:find('./', 1, true) then
    path_rel = path_rel:sub(3)
  end
  path_rel = path_rel:gsub('\\', '.')
  path_rel = path_rel:gsub('/', '.')
  if path_rel:sub(-3) == '.py' then
    path_rel = path_rel:sub(1, #path_rel - 3)
  end
  if cfg.path.collapse_dunder_init and path_rel:sub(-9) == '.__init__' then
    path_rel = path_rel:sub(1, #path_rel - 9)
  end
  return path_rel
end

-- Read autoimport mapping JSON and convert to name -> { import_line, ... }
local function read_import_json(path)
  local ok, stat = pcall(vim.uv.fs_stat or vim.loop.fs_stat, path)
  if not ok or not stat then return {} end
  local ok2, lines = pcall(vim.fn.readfile, path)
  if not ok2 then return {} end
  local ok3, obj = pcall(vim.json.decode or vim.fn.json_decode, table.concat(lines, '\n'))
  if not ok3 or type(obj) ~= 'table' then return {} end
  local ret = {}
  if type(obj.alias) == 'table' then
    for alias, module in pairs(obj.alias) do
      if type(alias) == 'string' and type(module) == 'string' then
        local txt
        if alias ~= module then txt = ('import %s as %s'):format(module, alias) else txt = ('import %s'):format(module) end
        ret[alias] = ret[alias] or {}
        table.insert(ret[alias], txt)
      end
    end
  end
  if type(obj.module) == 'table' then
    for module, funcs in pairs(obj.module) do
      if type(funcs) == 'string' then funcs = { funcs } end
      if type(funcs) == 'table' then
        for _, func in ipairs(funcs) do
          if type(func) == 'string' then
            local txt = ('from %s import %s'):format(module, func)
            ret[func] = ret[func] or {}
            table.insert(ret[func], txt)
          end
        end
      end
    end
  end
  return ret
end

-- Cache for working directory
local cached_cwd = nil
local cached_map = nil

-- Get autoimport map for current working directory.
-- If working json exists, use its merged result; else fall back to plugin default json.
function M.get_autoimport_map()
  local cwd = vim.fn.getcwd()
  if cached_cwd == cwd and cached_map ~= nil then
    return cached_map
  end
  cached_cwd = cwd
  local map_work = {}
  local p1 = vim.fs.joinpath(cwd, 'autoimport_for_python.json')
  local p2 = vim.fs.joinpath(cwd, 'autoimport_for_project.json')
  local m1 = read_import_json(p1)
  local m2 = read_import_json(p2)
  -- merge: later overrides earlier
  for k, v in pairs(m1) do map_work[k] = v end
  for k, v in pairs(m2) do map_work[k] = v end

  if next(map_work) ~= nil then
    cached_map = map_work
    return cached_map
  end

  -- Fallback to plugin default
  local default_json = vim.fs.joinpath(plugin_root(), 'data', 'autoimport_for_python.json')
  cached_map = read_import_json(default_json)
  return cached_map
end

-- Deduplicate list preserving order
local function dedup_list(list)
  local seen, out = {}, {}
  for _, v in ipairs(list or {}) do
    if v and v ~= '' and not seen[v] then
      table.insert(out, v)
      seen[v] = true
    end
  end
  return out
end

-- Read isort import headings from nearest config
function M.get_header_markers()
  local defaults = M.config.insert.header_markers or {}
  local MUST_HAVE = '# %% Import'

  local bufname = vim.api.nvim_buf_get_name(0)
  local start_dir = (bufname ~= '' and vim.fs.dirname(bufname)) or (vim.uv and vim.uv.cwd() or vim.loop.cwd())
  local candidates = { 'pyproject.toml', '.isort.cfg', 'setup.cfg', 'tox.ini' }

  local function read_lines(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok then return lines end
    return nil
  end

  local function parse_headings_from_pyproject(lines)
    local in_isort = false
    local heads = {}
    for _, line in ipairs(lines or {}) do
      if line:match('^%s*%[.+%]%s*$') then
        in_isort = line:match('%[tool%.isort%]') ~= nil
      elseif in_isort then
        local key, val = line:match('^%s*([%w_]+)%s*=%s*["\'](.-)["\']%s*$')
        if key and val and key:match('^import_heading_') then
          table.insert(heads, '# ' .. val)
        end
      end
    end
    return heads
  end

  local function parse_headings_from_ini(lines)
    local in_isort = false
    local heads = {}
    for _, line in ipairs(lines or {}) do
      local section = line:match('^%s*%[([^%]]+)%]%s*$')
      if section then
        in_isort = (section == 'isort' or section == 'tool:isort' or section == 'settings')
      elseif in_isort then
        local key, val = line:match('^%s*([%w_]+)%s*[:=]%s*["\']?(.-)["\']?%s*$')
        if key and val and key:match('^import_heading_') and #val > 0 then
          table.insert(heads, '# ' .. val)
        end
      end
    end
    return heads
  end

  local found = vim.fs.find(candidates, { path = start_dir, upward = true }) or {}
  local found_heads = nil
  for _, path in ipairs(found) do
    local lines = read_lines(path)
    if lines then
      local base = vim.fs.basename(path)
      if base == 'pyproject.toml' then
        found_heads = parse_headings_from_pyproject(lines)
      else
        found_heads = parse_headings_from_ini(lines)
      end
      if found_heads and #found_heads > 0 then
        break
      end
    end
  end

  local headers = {}
  if found_heads and #found_heads > 0 then
    headers = found_heads
  else
    headers = defaults
  end

  local final = {}
  table.insert(final, MUST_HAVE)
  for _, h in ipairs(headers or {}) do table.insert(final, h) end
  return dedup_list(final)
end

-- Find docstring end line (0-based), or nil
local function get_no_line_of_docstring()
  local no_lines_buf = vim.api.nvim_buf_line_count(0)
  local no_lines_max = math.min(no_lines_buf, M.config.insert.docstring_scan_lines)
  local lines = vim.api.nvim_buf_get_lines(0, 0, no_lines_max, false)
  local found_start = false
  for idx, line in ipairs(lines) do
    if not found_start and (line:find('"""', 1, true) or line:find("'''", 1, true) or line:find('r"""', 1, true) or line:find("r'''", 1, true)) then
      found_start = true
    end
    if found_start and #line > 2 then
      local suffix = line:sub(-3)
      if suffix == '"""' or suffix == "'''" then
        return idx - 1
      end
    end
  end
  return nil
end

-- Find preferred import insertion row (0-based). Returns row, or nil.
local function get_no_line_of_import()
  local ret = nil
  local no_lines_buf = vim.api.nvim_buf_line_count(0)
  local no_lines_max = math.min(no_lines_buf, M.config.insert.import_scan_lines)
  local lines = vim.api.nvim_buf_get_lines(0, 0, no_lines_max, false)
  local headers = M.get_header_markers()
  for idx, line in ipairs(lines) do
    local is_header = false
    for _, h in ipairs(headers) do
      if line == h then is_header = true; break end
    end
    if is_header then
      ret = idx -- below header
    elseif line:match('^%s*from%s+') or line:match('^%s*import%s+') then
      return idx - 1
    end
  end
  return ret
end

-- Insert imports: info_import = { name = module_path, ... }
function M.insert_import(info_import)
  if type(info_import) ~= 'table' then
    M.error('insert_import(): info_import must be a table { name = path }')
    return false
  end
  local no_line_docstring = get_no_line_of_docstring()
  local no_line_import = get_no_line_of_import()
  local no_line = 0
  if not no_line_docstring and not no_line_import then
    no_line = 0
  elseif no_line_docstring and not no_line_import then
    no_line = no_line_docstring + 1
  else
    no_line = no_line_import
  end

  -- Build and insert lines
  local names = {}
  for name, _ in pairs(info_import) do table.insert(names, name) end
  table.sort(names)
  local lines_to_insert = {}
  for _, name in ipairs(names) do
    local path = info_import[name]
    table.insert(lines_to_insert, ('from %s import %s'):format(path, name))
  end
  if M.config.insert.add_trailing_blank_line then table.insert(lines_to_insert, '') end
  if #lines_to_insert > 0 then
    local ok, err = pcall(vim.api.nvim_buf_set_text, 0, no_line, 0, no_line, 0, lines_to_insert)
    if not ok then
      M.error('Failed to insert import: ' .. tostring(err))
      return false
    end
  end

  -- Optionally isort
  local cmd = M.config.insert.isort_command
  if cmd and #cmd > 0 then
    local ok, err = pcall(vim.api.nvim_command, cmd)
    if not ok then M.warn('isort command failed: ' .. tostring(err)) end
  end
  return true
end

-- Insert raw import lines (e.g., 'import numpy as np') using same placement rules
function M.insert_import_lines(lines)
  if type(lines) ~= 'table' or #lines == 0 then return false end
  local no_line_docstring = get_no_line_of_docstring()
  local no_line_import = get_no_line_of_import()
  local no_line = 0
  if not no_line_docstring and not no_line_import then
    no_line = 0
  elseif no_line_docstring and not no_line_import then
    no_line = no_line_docstring + 1
  else
    no_line = no_line_import
  end
  local lines_to_insert = vim.deepcopy(lines)
  if M.config.insert.add_trailing_blank_line then table.insert(lines_to_insert, '') end
  local ok, err = pcall(vim.api.nvim_buf_set_text, 0, no_line, 0, no_line, 0, lines_to_insert)
  if not ok then M.error('Failed to insert import: ' .. tostring(err)); return false end
  local cmd = M.config.insert.isort_command
  if cmd and #cmd > 0 then pcall(vim.api.nvim_command, cmd) end
  return true
end

return M
