-- Register user commands for py-autoimport.nvim

-- Require Neovim 0.11+
if (vim.fn.has('nvim-0.11') or 0) ~= 1 then
  vim.notify('[py_autoimport] requires Neovim 0.11 or newer', vim.log.levels.ERROR, { title = 'py-autoimport' })
  return
end

local ok, mod = pcall(require, 'py_autoimport')
if not ok then
  vim.notify('[py_autoimport] failed to load module', vim.log.levels.ERROR, { title = 'py-autoimport' })
  return
end

-- Create command to run auto-import
vim.api.nvim_create_user_command('PyAutoImport', function()
  mod.auto_import()
end, { desc = 'Auto-import undefined Python symbols from workspace' })
