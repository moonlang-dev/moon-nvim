-- moon language support for Neovim: the `moon lsp` client, tree-sitter
-- highlighting and the file icon. plugin/moon.lua calls setup() with the
-- defaults; call it again to change them.
local M = {}

---@class moon.Options
---@field cmd? string[] Language server command. Default: { "moon", "lsp" }.
---@field lsp? boolean|table false starts no client; a table is merged into the client's config.
---@field highlight? boolean false leaves tree-sitter highlighting off.
---@field icon? boolean false registers no file icon.
M.options = {
  cmd = { "moon", "lsp" },
  lsp = true,
  highlight = true,
  icon = true,
}

--- The plugin's directory.
M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function setup_lsp()
  local options = M.options
  if options.lsp == false then
    return
  end
  local extra = type(options.lsp) == "table" and options.lsp or {}

  -- Neovim 0.11+ has a client of its own; older versions need nvim-lspconfig.
  if vim.lsp.config and vim.lsp.enable then
    vim.lsp.config(
      "moon",
      vim.tbl_deep_extend("force", {
        cmd = options.cmd,
        filetypes = { "moon" },
        root_markers = { "moon.toml", ".git" },
      }, extra)
    )
    vim.lsp.enable("moon")
    return
  end

  local ok, lspconfig = pcall(require, "lspconfig")
  if not ok then
    return
  end
  local configs = require("lspconfig.configs")
  if not configs.moon then
    configs.moon = {
      default_config = {
        cmd = options.cmd,
        filetypes = { "moon" },
        root_dir = require("lspconfig.util").root_pattern("moon.toml", ".git"),
        single_file_support = true,
      },
    }
  end
  lspconfig.moon.setup(vim.tbl_deep_extend("force", { cmd = options.cmd }, extra))
end

--- Starts tree-sitter highlighting in a moon buffer, when the parser is built.
---@param buf integer
function M.highlight(buf)
  if M.options.highlight ~= false then
    pcall(vim.treesitter.start, buf, "moon")
  end
end

---@param opts? moon.Options
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
  setup_lsp()
  if M.options.icon ~= false then
    require("moon.icon").setup()
  end
end

return M
