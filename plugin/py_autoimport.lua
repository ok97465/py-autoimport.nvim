-- Register user commands for py-autoimport.nvim

local ok, mod = pcall(require, 'py_autoimport')
if not ok then
  vim.notify('[py_autoimport] failed to load module', vim.log.levels.ERROR, { title = 'py-autoimport' })
  return
end

-- Create command to run auto-import
vim.api.nvim_create_user_command('PyAutoImport', function()
  mod.auto_import()
end, { desc = 'Auto-import undefined Python symbols from workspace' })

