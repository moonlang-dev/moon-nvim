-- Compiles the tree-sitter grammar into parser/moon.so and copies its queries
-- to queries/moon/, both inside the plugin's directory and so on the
-- runtimepath. Needs a C compiler and no tree-sitter CLI.
local M = {}

local uv = vim.uv or vim.loop
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

--- Finds the grammar: beside the plugin's files in the published plugin,
--- a sibling directory in the moon repository.
---@return string?
function M.grammar_dir()
  for _, dir in ipairs({ root .. "/tree-sitter-moon", vim.fn.fnamemodify(root, ":h") .. "/tree-sitter-moon" }) do
    if uv.fs_stat(dir .. "/src/parser.c") then
      return dir
    end
  end
end

--- Finds a C compiler: `$CC`, then cc, gcc, clang and `zig cc`.
---@return string[]?
function M.compiler()
  local candidates = { { "cc" }, { "gcc" }, { "clang" }, { "zig", "cc" } }
  if vim.env.CC and vim.env.CC ~= "" then
    table.insert(candidates, 1, vim.split(vim.env.CC, " ", { trimempty = true }))
  end
  for _, argv in ipairs(candidates) do
    if vim.fn.executable(argv[1]) == 1 then
      return argv
    end
  end
end

-- Inside lazy.nvim's build task the wait yields, so the editor stays live.
local function run(argv)
  if not vim.system then
    local output = vim.fn.system(argv)
    return vim.v.shell_error, output
  end
  local yieldable = coroutine.isyieldable and coroutine.isyieldable()
  if not yieldable then
    local result = vim.system(argv, { text = true }):wait()
    return result.code, result.stderr
  end
  local result
  vim.system(argv, { text = true }, function(done)
    result = done
  end)
  while not result do
    coroutine.yield()
  end
  return result.code, result.stderr
end

--- Builds the parser and installs the queries.
---@param opts? { notify?: boolean }
---@return boolean ok
---@return string? err
function M.run(opts)
  local notify = not opts or opts.notify ~= false
  local function fail(message)
    if notify then
      vim.notify("moon: " .. message, vim.log.levels.ERROR)
    end
    return false, message
  end

  local grammar = M.grammar_dir()
  if not grammar then
    return fail("the tree-sitter-moon grammar was not found beside " .. root)
  end
  local cc = M.compiler()
  if not cc then
    return fail("no C compiler found (set $CC, or install cc, gcc, clang or zig)")
  end

  -- Neovim loads the first parser/moon.* it finds, on every platform, so the
  -- compiler writes into a directory of its own and only moon.so is moved up:
  -- on Windows the import library and debug file would otherwise shadow it.
  local stage = root .. "/parser/build"
  vim.fn.delete(stage, "rf")
  vim.fn.mkdir(stage, "p")
  vim.fn.mkdir(root .. "/queries/moon", "p")
  local argv = vim.list_extend(vim.deepcopy(cc), {
    "-O2",
    "-shared",
    "-fPIC",
    "-I" .. grammar .. "/src",
    grammar .. "/src/parser.c",
    grammar .. "/src/scanner.c",
    "-o",
    stage .. "/moon.so",
  })
  local code, output = run(argv)
  if code ~= 0 then
    vim.fn.delete(stage, "rf")
    return fail(("%s failed:\n%s"):format(table.concat(cc, " "), output or ""))
  end

  -- A rename replaces the file a running session has mapped instead of
  -- writing into it.
  local parser = root .. "/parser/moon.so"
  local moved = uv.fs_rename(stage .. "/moon.so", parser)
  vim.fn.delete(stage, "rf")
  if not moved then
    return fail("could not replace " .. parser .. " (close the sessions that have it loaded)")
  end
  for _, query in ipairs(vim.fn.glob(grammar .. "/queries/*.scm", false, true)) do
    uv.fs_copyfile(query, root .. "/queries/moon/" .. vim.fn.fnamemodify(query, ":t"))
  end

  if notify then
    vim.notify("moon: built " .. parser)
  end
  return true
end

return M
