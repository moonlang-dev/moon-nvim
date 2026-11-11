local M = {}

function M.check()
  local health = vim.health
  local moon = require("moon")
  health.start("moon")

  local cmd = moon.options.cmd[1]
  if moon.options.lsp == false then
    health.info("the language server is disabled (`lsp = false`)")
  elseif vim.fn.executable(cmd) == 1 then
    local version = vim.trim(vim.fn.system({ cmd, "--version" }))
    health.ok(("`%s` found: %s"):format(cmd, version))
  else
    health.error(("`%s` is not executable"):format(cmd), {
      "Install the moon toolchain, or set `cmd` in the plugin's options.",
    })
  end

  if pcall(vim.treesitter.language.inspect, "moon") then
    health.ok("the tree-sitter parser loads")
  else
    health.warn("the tree-sitter parser is not built", { "Run `:MoonBuild` (it needs a C compiler)." })
  end

  if #vim.api.nvim_get_runtime_file("queries/moon/highlights.scm", false) > 0 then
    health.ok("the highlight queries are installed")
  else
    health.warn("the highlight queries are missing", { "Run `:MoonBuild`." })
  end
end

return M
