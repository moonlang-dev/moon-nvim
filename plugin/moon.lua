-- One moon integration per session: the setup.sh / setup.ps1 install writes
-- its own plugin/moon.lua, which honours the same guard.
if vim.g.loaded_moon then
  return
end
vim.g.loaded_moon = true

require("moon").setup()

vim.api.nvim_create_user_command("MoonBuild", function()
  require("moon.build").run()
end, { desc = "Compile the tree-sitter parser for moon" })
