# setup.ps1 — install moon language support into Neovim (Windows).
#
# Windows equivalent of editors/nvim/setup.sh. Produces a self-contained,
# PLUGIN-FREE setup that works on Neovim 0.11+ using the built-in LSP client
# (vim.lsp.config / vim.lsp.enable) and the built-in tree-sitter runtime. It:
#
#   1. builds the `moon` toolchain (via `zig build`) if it is not already built,
#   2. compiles the in-repo tree-sitter grammar (src/parser.c + src/scanner.c)
#      into a loadable `moon.so` using `zig cc` (no tree-sitter CLI required;
#      zig is already required for step 1, so no separate C compiler is needed),
#   3. installs the parser, the highlight/injection/locals queries, a filetype
#      rule, and an autoloaded Lua config into your Neovim runtime directory,
#   4. verifies the parser loads and the LSP is registered, headlessly.
#
# Re-running is safe (idempotent): installed files are overwritten in place.
#
# Usage:
#   pwsh -File editors/nvim/setup.ps1 [-Rebuild] [-ConfigDir DIR] [-Uninstall] [-Help]
#
#     -Rebuild        force `zig build` even if `moon.exe` already exists
#     -ConfigDir DIR  install into DIR instead of the detected Neovim config dir
#     -Uninstall      remove everything this script installs, then exit
#     -Help           show this message
#
# Note: even on Windows, Neovim loads tree-sitter parsers named `<lang>.so`
# (the `.so` extension is used on every platform), so the parser is `moon.so`.

[CmdletBinding()]
param(
  [switch]$Rebuild,
  [string]$ConfigDir,
  [string]$ExecutableDir,
  [switch]$Uninstall,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info([string]$msg)
{ Write-Host "==> " -ForegroundColor Green -NoNewline; Write-Host $msg 
}
function Write-Warn([string]$msg)
{ Write-Host "! $msg" -ForegroundColor Yellow 
}
function Die([string]$msg)
{ Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 
}

function Show-Usage
{
  @'
setup.ps1 — install moon language support into Neovim (Windows, plugin-free, 0.11+).

Usage:
  pwsh -File editors/nvim/setup.ps1 [-Rebuild] [-ConfigDir DIR] [-Uninstall] [-Help]

    -Rebuild            force `zig build` even if `moon.exe` already exists
    -ConfigDir DIR      install into DIR instead of the detected Neovim config dir
    -ExecutableDir DIR  directory containing the `moon.exe` executable
    -Uninstall          remove everything this script installs, then exit
    -Help               show this message
'@ | Write-Host
}

if ($Help)
{ Show-Usage; exit 0 
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
# The published plugin (moonlang-dev/moon-nvim) carries the grammar beside this
# script; in the moon repository it is a sibling directory.
$GrammarDir = Join-Path $ScriptDir 'tree-sitter-moon'
if (-not (Test-Path -LiteralPath $GrammarDir))
{ $GrammarDir = Join-Path $RepoRoot 'editors/tree-sitter-moon'
}
if (-not $ExecutableDir)
{
  if ($env:MOON)
  {
    $MoonBin  = $env:MOON
  } elseif (Get-Command 'moon' -ErrorAction SilentlyContinue)
  {
    $MoonBin  = (Get-Command 'moon').Source
  } else
  {
    # Each optimize mode installs into its own tree: `zig build` (what this
    # script runs) into zig-out\, `-Doptimize=ReleaseFast` into
    # zig-out-release\. Prefer the Debug tree, falling back to the release one
    # so a checkout that only ever builds ReleaseFast is not rebuilt here.
    $MoonBin    = Join-Path $RepoRoot 'zig-out\bin\moon.exe'
    $ReleaseBin = Join-Path $RepoRoot 'zig-out-release\bin\moon.exe'
    if (-not (Test-Path -LiteralPath $MoonBin) -and (Test-Path -LiteralPath $ReleaseBin))
    {
      $MoonBin  = $ReleaseBin
    }
  }
} else
{
  $MoonBin    = Join-Path $ExecutableDir 'moon.exe'
}
# Neovim config (runtime) directory on Windows — everything installed here is on
# the runtimepath automatically. Neovim uses $LOCALAPPDATA\nvim for stdpath config.
if (-not $ConfigDir)
{
  $localAppData = if ($env:LOCALAPPDATA)
  { $env:LOCALAPPDATA 
  } else
  { Join-Path $env:USERPROFILE 'AppData\Local' 
  }
  $NvimDir = Join-Path $localAppData 'nvim'
} else
{
  $NvimDir = $ConfigDir
}

$ParserDest   = Join-Path $NvimDir 'parser\moon.so'
$QueryDest    = Join-Path $NvimDir 'queries\moon'
$PluginDest   = Join-Path $NvimDir 'plugin\moon.lua'
$FtdetectDest = Join-Path $NvimDir 'ftdetect\moon.vim'
$IconDest     = Join-Path $NvimDir 'icons\moon.png'
$IconDarkDest = Join-Path $NvimDir 'icons\moon-dark.png'
$SpecDest     = Join-Path $NvimDir 'lua\plugins\moon.lua'

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if ($Uninstall)
{
  Write-Info "Removing moon support from $NvimDir"
  $targets = @(
    $ParserDest, $PluginDest, $FtdetectDest, $IconDest, $IconDarkDest, $SpecDest,
    (Join-Path $QueryDest 'highlights.scm'),
    (Join-Path $QueryDest 'injections.scm'),
    (Join-Path $QueryDest 'locals.scm')
  )
  foreach ($t in $targets)
  {
    if (Test-Path -LiteralPath $t)
    { Remove-Item -LiteralPath $t -Force; Write-Host "  removed $t" 
    }
  }
  # Only remove these if this script emptied them; they are shared directories.
  foreach ($d in @($QueryDest, (Split-Path -Parent $IconDest), (Split-Path -Parent $SpecDest)))
  {
    if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force))
    { Remove-Item -LiteralPath $d -Force 
    }
  }
  Write-Info "Done."
  exit 0
}

# ---------------------------------------------------------------------------
# 1. Build the moon toolchain (LSP server lives in this binary)
# ---------------------------------------------------------------------------
function Test-Command([string]$name)
{ [bool](Get-Command $name -ErrorAction SilentlyContinue) 
}

# The release bundle has an empty build.zig, only so anyzig can choose a version.
$BuildFile = Join-Path $RepoRoot 'build.zig'
$IsCheckout = (Test-Path -LiteralPath $BuildFile -PathType Leaf) -and
  (Get-Item -LiteralPath $BuildFile).Length -gt 0

if ($Rebuild -or -not (Test-Path -LiteralPath $MoonBin))
{
  if ($IsCheckout -and (Test-Command 'zig'))
  {
    Write-Info "Building the moon toolchain (zig build)…"
    Push-Location $RepoRoot
    try
    { & zig build; if ($LASTEXITCODE -ne 0)
      { Die "zig build failed" 
      } 
    } finally
    { Pop-Location 
    }
    # Plain `zig build` is Debug, so it installs into zig-out\ — re-point at it,
    # or a binary found in the release tree above would shadow the fresh one.
    if (-not $ExecutableDir -and -not $env:MOON)
    {
      $MoonBin  = Join-Path $RepoRoot 'zig-out\bin\moon.exe'
    }
  } elseif (Test-Path -LiteralPath $MoonBin)
  {
    Write-Warn "toolchain rebuild is unavailable; using the existing binary at $MoonBin"
  } else
  {
    if ($IsCheckout)
    {
      Die "zig was not found and no prebuilt moon executable exists at $MoonBin — install Zig or set `$env:MOON to an existing executable."
    } else
    {
      Die "moon was not found on PATH and this bundle has no compiler source — install the moon toolchain first, or set `$env:MOON to its executable."
    }
  }
}
if (-not (Test-Path -LiteralPath $MoonBin))
{ Die "expected the moon binary at $MoonBin after building" 
}

# Prefer a `moon` already on PATH; otherwise fall back to the absolute path.
if (Test-Command 'moon')
{
  Write-Info "LSP server: found 'moon' on PATH"
} else
{
  Write-Info "LSP server: not on PATH — the config will use the absolute path $MoonBin"
}

# ---------------------------------------------------------------------------
# 2. Compile the tree-sitter parser (+ external scanner) into moon.so
# ---------------------------------------------------------------------------
# Prefer `zig cc` (guaranteed present, since zig builds the toolchain). Honor an
# explicit $env:CC, then fall back to gcc / clang for users who have them.
$ccExe = $null; $ccPre = @()
if ($env:CC)
{
  # Allow "zig cc" or a plain compiler name in $env:CC.
  $parts = $env:CC -split '\s+'
  $ccExe = $parts[0]; if ($parts.Count -gt 1)
  { $ccPre = $parts[1..($parts.Count-1)] 
  }
} elseif (Test-Command 'zig')
{
  $ccExe = 'zig'; $ccPre = @('cc')
} elseif (Test-Command 'gcc')
{
  $ccExe = 'gcc'
} elseif (Test-Command 'clang')
{
  $ccExe = 'clang'
} else
{
  Die "no C compiler found (set `$env:CC, or install zig/gcc/clang) — needed to build the tree-sitter parser."
}

$parserC  = Join-Path $GrammarDir 'src\parser.c'
$scannerC = Join-Path $GrammarDir 'src\scanner.c'
if (-not (Test-Path -LiteralPath $parserC))
{ Die "missing $parserC" 
}
if (-not (Test-Path -LiteralPath $scannerC))
{ Die "missing $scannerC (external scanner for nested block comments)" 
}

Write-Info "Compiling the tree-sitter grammar with '$ccExe $($ccPre -join ' ')' → moon.so"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ParserDest) | Out-Null
# anyzig finds its zig version from the working directory, so compile from the
# root that holds build.zig.zon rather than wherever this script was started.
$ParserOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ParserDest)
Push-Location $RepoRoot
try
{
  & $ccExe @ccPre -O2 -shared "-I$(Join-Path $GrammarDir 'src')" $parserC $scannerC -o $ParserOutput
} finally
{ Pop-Location 
}
if ($LASTEXITCODE -ne 0)
{ Die "compiling the tree-sitter parser failed" 
}

# zig cc / clang emit a debug sidecar (moon.pdb, moon.lib, ...) next to moon.so.
# Neovim resolves a parser by globbing `parser/<lang>.*` and loading the FIRST
# match — moon.pdb sorts before moon.so, so it would shadow the real parser and
# fail to load. Remove every parser/moon.* except moon.so.
Get-ChildItem -LiteralPath (Split-Path -Parent $ParserDest) -Filter 'moon.*' -File |
  Where-Object { $_.Name -ne 'moon.so' } |
  ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

Write-Info "Installed parser → $ParserDest"

# ---------------------------------------------------------------------------
# 3. Install queries (highlights / injections / locals)
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $QueryDest | Out-Null
foreach ($q in @('highlights', 'injections', 'locals'))
{
  $src = Join-Path $GrammarDir "queries\$q.scm"
  if (Test-Path -LiteralPath $src)
  { Copy-Item -LiteralPath $src -Destination (Join-Path $QueryDest "$q.scm") -Force 
  }
}
Write-Info "Installed queries → $QueryDest\"

# ---------------------------------------------------------------------------
# 4. Install the filetype rule + autoloaded Lua config
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $FtdetectDest) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PluginDest)   | Out-Null

$ftdetect = @'
" Detect moon source files (installed by editors/nvim/setup.ps1).
autocmd BufRead,BufNewFile *.mn setfiletype moon
'@
Set-Content -LiteralPath $FtdetectDest -Value $ftdetect -Encoding utf8

# The Lua config is emitted with the resolved moon binary path baked in as a
# fallback. `plugin/` files are auto-sourced by Neovim at startup. The binary
# path is inserted into a Lua long-bracket string [[...]] so backslashes are not
# treated as escapes on Windows.
$pluginTemplate = @'
-- moon language support for Neovim (installed by editors/nvim/setup.ps1).
-- Plugin-free: uses Neovim's built-in LSP (0.11+) and tree-sitter runtimes.
-- Re-run editors/nvim/setup.ps1 from the moon repo to refresh.

-- One moon integration per session: the lazy.nvim plugin (moonlang-dev/moon-nvim)
-- sets the same guard and, loading first, takes over from this file.
if vim.g.loaded_moon then
  return
end
vim.g.loaded_moon = true

-- 1. Filetype ---------------------------------------------------------------
vim.filetype.add({ extension = { mn = "moon" } })

-- Resolve the language server command: prefer a 'moon' on PATH, else the
-- absolute path to the binary this machine built.
local moon_cmd = (vim.fn.executable("moon") == 1) and "moon"
  or [[__MOON_BIN__]]

-- 2. LSP --------------------------------------------------------------------
-- Native client (Neovim 0.11+). Falls back to nvim-lspconfig on older versions.
if vim.lsp and vim.lsp.config and vim.lsp.enable then
  vim.lsp.config("moon", {
    cmd = { moon_cmd, "lsp" },
    filetypes = { "moon" },
    root_markers = { "moon.toml", ".git" },
  })
  vim.lsp.enable("moon")
else
  local ok, lspconfig = pcall(require, "lspconfig")
  if ok then
    local configs = require("lspconfig.configs")
    local util = require("lspconfig.util")
    if not configs.moon then
      configs.moon = {
        default_config = {
          cmd = { moon_cmd, "lsp" },
          filetypes = { "moon" },
          root_dir = util.root_pattern("moon.toml", ".git"),
          single_file_support = true,
        },
      }
    end
    lspconfig.moon.setup({})
  end
end

-- 3. Per-buffer options + tree-sitter highlighting --------------------------
vim.api.nvim_create_autocmd("FileType", {
  pattern = "moon",
  callback = function(args)
    vim.bo[args.buf].commentstring = "// %s"
    vim.bo[args.buf].comments = ":\\/\\/"
    -- Built-in tree-sitter highlighting (parser + queries installed alongside).
    pcall(vim.treesitter.start, args.buf, "moon")
  end,
})

-- 4. File icon --------------------------------------------------------------
-- Two providers, in preference order:
--
--   real-icons.nvim      draws real images, so it can show the moon mark
--                        itself (moon.png, the same logo the other editors
--                        use). Requires a terminal with a graphics protocol
--                        (Kitty or Ghostty) and ImageMagick's magick.
--   nvim-web-devicons    draws font glyphs only, so the best it can do is a
--                        moon character in the mark's colour.
--
-- Both are registered when present. The glyph is registered first as the base,
-- because real-icons falls back to nvim-web-devicons by itself on terminals
-- without graphics support -- so registering both is what makes that fallback
-- show a moon rather than a generic default file icon.
-- See lua/plugins/moon.lua for how the providers get installed.
--
-- The mark is a single-colour silhouette, so it is installed in two inks:
-- moon.png is near-black for a light background and moon-dark.png is white for
-- a dark one. 'background' picks between them, and is re-read when it changes.
-- Set vim.g.moon_icon_path to use one image for both backgrounds instead.
local function resolve_moon_icon()
  if vim.g.moon_icon_path then
    return vim.fn.expand(vim.g.moon_icon_path)
  end
  if vim.o.background == "dark" then
    return [[__ICON_DARK__]]
  end
  return [[__ICON__]]
end

local moon_icon = resolve_moon_icon()

-- real-icons ships its integrations disabled by default. Each one is enabled
-- here when -- and only when -- its host plugin is actually installed.
--
-- The lookup is a runtime-path probe rather than pcall(require, ...) on the
-- host plugin: requiring it would drag a lazily loaded plugin in at startup,
-- which is exactly what its author deferred. Plugins that load later are
-- picked up by the LazyLoad hook at the bottom of this section.
local icon_integrations = {
  bufferline = "bufferline",
  fzf_lua = "fzf-lua",
  lualine = "lualine",
  mini_files = "mini.files",
  neo_tree = "neo-tree",
  nvim_tree = "nvim-tree",
  oil = "oil",
  snacks_picker = "snacks.picker",
  telescope = "telescope",
  telescope_file_browser = "telescope._extensions.file_browser",
}

local function module_present(name)
  if package.loaded[name] then
    return true
  end
  local rel = name:gsub("%.", "/")
  return #vim.api.nvim_get_runtime_file("lua/" .. rel .. ".lua", false) > 0
    or #vim.api.nvim_get_runtime_file("lua/" .. rel .. "/init.lua", false) > 0
end

local enabled_integrations = {}

-- neo-tree flattens default_component_configs into a fresh per-component table
-- when its config is merged, and the renderer reads that copy. Two things make
-- that a race real-icons loses:
--
--   * neo-tree 3.x merges lazily, but `hijack_netrw_behavior` forces the merge
--     during its own setup() -- long before plugin/ files are sourced.
--   * re-running setup() does not repair it. The merge does
--     `for k, v in pairs(global_config)` then `for k, v in pairs(component)`,
--     so the component wins -- and on a second pass the component is the
--     previously flattened table, whose stale `provider` key overwrites the
--     patched global every time.
--
-- So write the provider straight into the flattened tables instead. Whatever
-- real-icons put on default_component_configs.icon is the source of truth; if
-- it never enabled its integration, that is still neo-tree's own provider and
-- copying it changes nothing.
--
-- Set vim.g.moon_icon_neotree_refresh = false to leave neo-tree alone.
local function apply_neo_tree_provider()
  if vim.g.moon_icon_neotree_refresh == false then
    return
  end

  -- package.loaded, not require: never load neo-tree just to reconfigure it.
  local neo_tree = package.loaded["neo-tree"]
  local neo_tree_config = neo_tree and rawget(neo_tree, "config")
  -- Nil means the merge has not happened yet, and the defaults real-icons
  -- patched will be picked up cleanly when it does. Nothing to repair.
  if not neo_tree_config then
    return
  end

  local icon = neo_tree_config.default_component_configs
    and neo_tree_config.default_component_configs.icon
  if type(icon) ~= "table" or type(icon.provider) ~= "function" then
    return
  end

  local function inject(components)
    for _, component in ipairs(components or {}) do
      if component[1] == "icon" then
        component.provider = icon.provider
        component.use_filtered_colors = icon.use_filtered_colors
      elseif component[1] == "container" then
        inject(component.content)
      end
    end
  end

  for _, source in ipairs(neo_tree_config.sources or {}) do
    local src = neo_tree_config[source]
    for _, renderer in pairs(src and src.renderers or {}) do
      inject(renderer)
    end
  end
end

-- Scope images to .mn files.
--
-- real-icons replaces every file icon in whichever integration it is enabled
-- for, which is more than a language integration should take over. Ask for
-- image = false on anything that did not resolve to the moon mark: both
-- M.segment and M.render gate on `opts.image ~= false`, so that falls through
-- to icon.fallback -- the glyph real-icons already resolves from mini.icons or
-- nvim-web-devicons -- and the rest of the tree keeps its Nerd Font icons.
--
-- One hook covers every integration, since they all render through this
-- module. Note it also applies to :lua require("real-icons").demo(), which
-- will show glyphs rather than images while this is on.
--
-- Set vim.g.moon_icon_only = false for real-icons' normal behaviour: images
-- for everything it can resolve.
local function scope_images_to_moon()
  if vim.g.moon_icon_only == false then
    return
  end

  local ok_renderer, renderer = pcall(require, "real-icons.render.placeholder")
  if not ok_renderer or renderer.__moon_scoped then
    return
  end
  if type(renderer.segment) ~= "function" or type(renderer.render) ~= "function" then
    return
  end

  local function scoped(icon, opts)
    if type(icon) == "table" and (icon.source == moon_icon or icon.asset == moon_icon) then
      return opts
    end
    return vim.tbl_extend("force", opts or {}, { image = false })
  end

  local segment = renderer.segment
  renderer.segment = function(icon, opts)
    return segment(icon, scoped(icon, opts))
  end

  local render = renderer.render
  renderer.render = function(bufnr, row, col, icon, opts)
    return render(bufnr, row, col, icon, scoped(icon, opts))
  end

  renderer.__moon_scoped = true
end

local function enable_icon_integrations()
  local ok_icons, real_icons = pcall(require, "real-icons")
  if not ok_icons then
    return
  end

  for integration, module in pairs(icon_integrations) do
    if not enabled_integrations[integration] and module_present(module) then
      enabled_integrations[integration] = true
      -- Each integration re-checks its own host plugin and reports a failure
      -- rather than raising, so a false return here is not worth acting on.
      pcall(real_icons.enable_integration, integration)
    end
  end
end

-- real-icons uploads with the Kitty graphics protocol's t=f medium: the
-- payload is the PNG's *path*, and the terminal opens that file itself --
-- backend/kitty.lua never reads the image. That assumes the terminal and
-- Neovim share a filesystem.
--
-- Over SSH they do not. The terminal is handed a path that exists only on the
-- remote, draws nothing, and q=2 in the control string suppresses the error
-- reply, so upload() reports success and nothing anywhere records a failure.
--
-- t=d carries the bytes inline and works across the boundary. Upstream
-- hardcodes t=f, so replace upload() with a chunked t=d transmit -- but only
-- in an SSH session, leaving the cheaper local path exactly as it is.
local function ssh_session()
  return vim.env.SSH_CONNECTION ~= nil
    or vim.env.SSH_TTY ~= nil
    or vim.env.SSH_CLIENT ~= nil
end

local remote_transport_ready = false
local KITTY_ESC = "\27"
local KITTY_CHUNK = 4096

local function patch_remote_image_transport()
  if not ssh_session() or not (vim.base64 and vim.base64.encode) then
    return
  end

  local ok_backend, backend = pcall(require, "real-icons.backend.kitty")
  if not ok_backend or backend.__moon_direct_transport then
    return
  end

  -- This rides on another plugin's internals, so bail out rather than
  -- half-patch if the shape is not what it was written against.
  if
    type(backend.upload) ~= "function"
    or type(backend.image_id) ~= "function"
    or type(backend.wrap_for_tmux) ~= "function"
    or type(backend.clear_uploaded) ~= "function"
  then
    return
  end

  local icons_config = require("real-icons.config")
  local sent = {}

  local function send(data)
    data = backend.wrap_for_tmux(data)
    if vim.v.stderr and vim.v.stderr > 0 then
      vim.api.nvim_chan_send(vim.v.stderr, data)
    else
      io.stderr:write(data)
      io.stderr:flush()
    end
  end

  backend.upload = function(icon, opts)
    opts = opts or {}
    local asset = icon and icon.asset
    if not asset then
      return nil, "asset does not exist: " .. tostring(asset)
    end

    local cached = sent[asset]
    if cached then
      return cached
    end

    local handle = io.open(asset, "rb")
    if not handle then
      return nil, "asset does not exist: " .. asset
    end
    local bytes = handle:read("*a")
    handle:close()
    if not bytes or bytes == "" then
      return nil, "asset is empty: " .. asset
    end

    local size = opts.size or icons_config.options.size
    local cols = opts.cols or size.cols
    local rows = opts.rows or size.rows
    local image_id = backend.image_id(asset)
    local payload = vim.base64.encode(bytes)

    -- Each escape carries at most 4096 base64 bytes; m=1 means "more to
    -- follow", and only the first chunk carries the full control block.
    local out, offset, first = {}, 1, true
    while offset <= #payload do
      local chunk = payload:sub(offset, offset + KITTY_CHUNK - 1)
      offset = offset + KITTY_CHUNK
      local more = offset <= #payload and 1 or 0
      local control
      if first then
        first = false
        control = table.concat({
          "a=T",
          "f=100",
          "t=d",
          "q=2",
          "U=1",
          "i=" .. image_id,
          "c=" .. cols,
          "r=" .. rows,
          "m=" .. more,
        }, ",")
      else
        control = "m=" .. more
      end
      out[#out + 1] = KITTY_ESC .. "_G" .. control .. ";" .. chunk .. KITTY_ESC .. "\\"
    end

    send(table.concat(out))
    sent[asset] = image_id
    return image_id
  end

  local clear_uploaded = backend.clear_uploaded
  backend.clear_uploaded = function(...)
    -- Upstream only deletes ids it uploaded itself, so drop ours too.
    local deletes = {}
    for _, image_id in pairs(sent) do
      deletes[#deletes + 1] = KITTY_ESC .. "_Ga=d,d=I,q=2,i=" .. image_id .. KITTY_ESC .. "\\"
    end
    if #deletes > 0 then
      send(table.concat(deletes))
    end
    sent = {}
    return clear_uploaded(...)
  end

  backend.__moon_direct_transport = true
  remote_transport_ready = true
end

-- Selecting the backend is deliberately NOT done above. enable_integration()
-- falls back to real-icons' own setup() when it has not run yet, and that
-- rebuilds every option from the defaults -- so anything written before the
-- integrations are enabled is silently reset. This runs after them.
--
-- Detection cannot see Ghostty over SSH: ssh forwards TERM but not
-- TERM_PROGRAM or GHOSTTY_RESOURCES_DIR, so without this it reports no
-- support and drops to glyphs. Forcing it WITHOUT the transport patch above is
-- worse than useless -- it trades a working glyph for an invisible
-- placeholder -- hence the remote_transport_ready guard.
local function force_remote_backend()
  if not remote_transport_ready then
    return
  end

  local term = (vim.env.TERM or ""):lower()
  if not (term:find("ghostty", 1, true) or term:find("kitty", 1, true)) then
    return
  end

  local ok_config, icons_config = pcall(require, "real-icons.config")
  if not ok_config or icons_config.options.backend ~= "auto" then
    return
  end
  icons_config.options.backend = "kitty"

  -- Drop caches so anything resolved while uploads were silently failing gets
  -- rebuilt against the working transport.
  pcall(function()
    require("real-icons.backend.kitty").detect({ refresh = true })
    require("real-icons.render.placeholder").reset_cache()
  end)
end

local function register_real_icon()
  local ok_icons, icons_config = pcall(require, "real-icons.config")
  if not ok_icons or vim.fn.filereadable(moon_icon) ~= 1 then
    return
  end

  -- Integrations first: enable_integration() falls back to real-icons' own
  -- setup() when it has not run yet, which rebuilds options from defaults.
  -- Writing the override afterwards keeps it from being reset.
  scope_images_to_moon()
  enable_icon_integrations()
  force_remote_backend()
  apply_neo_tree_provider()

  -- Write into the live options table rather than calling
  -- require("real-icons").setup(): that rebuilds every option from the plugin
  -- defaults and would discard the config you already set.
  local overrides = icons_config.options.overrides or {}
  overrides.extensions = overrides.extensions or {}
  if overrides.extensions.mn ~= moon_icon then
    overrides.extensions.mn = moon_icon
    icons_config.options.overrides = overrides
    -- Resolved icons are memoized per lookup, so drop the cache to pick up
    -- the override for .mn buffers that were already resolved.
    pcall(function()
      require("real-icons.resolver").clear_cache()
    end)
  end
end

local function register_devicons_glyph()
  local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
  if not ok_devicons then
    return
  end

  devicons.set_icon({
    mn = { icon = "", color = "#c8c3ff", cterm_color = "189", name = "moon" },
  })
end

local function register_moon_icon()
  moon_icon = resolve_moon_icon()
  patch_remote_image_transport()
  register_devicons_glyph()
  register_real_icon()
end

register_moon_icon()

-- Re-apply after startup. Three reasons: a plugin manager may load either
-- provider after this file runs, real-icons' setup() rebuilds its options from
-- defaults (dropping the override), and lazily loaded integrations only become
-- detectable once they load.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = register_moon_icon,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "LazyLoad",
  callback = register_moon_icon,
})

-- A colorscheme change flips 'background', which is what chooses the ink. The
-- re-registration rewrites the override and drops real-icons' resolver cache,
-- so .mn buffers that were already on screen pick up the other image.
vim.api.nvim_create_autocmd("OptionSet", {
  pattern = "background",
  callback = register_moon_icon,
})
'@
$plugin = $pluginTemplate.Replace('__MOON_BIN__', $MoonBin).Replace('__ICON_DARK__', $IconDarkDest).Replace('__ICON__', $IconDest)
Set-Content -LiteralPath $PluginDest -Value $plugin -Encoding utf8

Write-Info "Installed config → $PluginDest"
Write-Info "Installed filetype rule → $FtdetectDest"

# ---------------------------------------------------------------------------
# 5. Install the file icon + a lazy.nvim spec for the icon providers
# ---------------------------------------------------------------------------
# The images are copied in rather than referenced in place, so the install keeps
# working if this repository is later moved or deleted. Both inks go in; the
# config above picks one by 'background'.
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $IconDest) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SpecDest) | Out-Null
Copy-Item -LiteralPath (Join-Path $ScriptDir 'moon.png') -Destination $IconDest -Force
Copy-Item -LiteralPath (Join-Path $ScriptDir 'moon-dark.png') -Destination $IconDarkDest -Force
Write-Info "Installed file icon → $IconDest"
Write-Info "Installed file icon (dark background) → $IconDarkDest"

$specTemplate = @'
-- moon icon providers (installed by editors/nvim/setup.ps1).
--
-- moon language support itself is PLUGIN-FREE: the parser, queries, filetype
-- rule and LSP config are installed straight into your Neovim config
-- directory and need no plugin manager. This file exists only to install the
-- providers that draw the moon mark on .mn files.
--
-- It is a lazy.nvim spec, so it is picked up only if your config imports this
-- directory (`require("lazy").setup({ { import = "plugins" } })`, which is
-- also the LazyVim layout). Under any other plugin manager this file is inert
-- -- install the dependencies below by hand instead.

return {
  {
    -- Anchor for the dependency list: the integration itself is already
    -- installed, so lazy has nothing to fetch or load for it.
    virtual = true,
    name = "moon",
    lazy = false,

    -- Options are plain globals: plugin/moon.lua is sourced by Neovim itself
    -- rather than loaded by lazy, so there is no setup() to hand opts to.
    init = function()
      -- neo-tree copies default_component_configs into per-component tables
      -- when its setup() runs, and the renderer reads those copies. real-icons
      -- enables its integration afterwards and patches the original table,
      -- which nothing consults any more -- so .mn files keep rendering
      -- neo-tree's default icon even though "provider" is visible in
      -- neo-tree's config.
      --
      -- plugin/moon.lua works around that by re-running neo-tree's setup()
      -- with its own config once the provider is in place, rebuilding those
      -- copies. Set this to false to leave neo-tree untouched -- icons will
      -- then not appear in it unless you name the provider in your own
      -- neo-tree opts:
      --
      --   opts = { default_component_configs = { icon = {
      --     provider = require("real-icons.integrations.neo_tree").provider,
      --     use_filtered_colors = false,
      --   } } }
      vim.g.moon_icon_neotree_refresh = true

      -- Point this at an image if you move them out of the config dir. One
      -- path serves both backgrounds, so set it to the ink your colorscheme
      -- wants: moon.png on a light background, moon-dark.png on a dark one.
      -- vim.g.moon_icon_path = "/path/to/moon-dark.png"
    end,

    dependencies = {
      -- Renders real images instead of font glyphs, so .mn files get the
      -- actual moon logo. Needs a terminal with a graphics protocol (Kitty
      -- or Ghostty) and ImageMagick's `magick`; `build` fetches the icon
      -- pack it renders everything else from.
      {
        "Mirsmog/real-icons.nvim",
        build = ":RealIcons install",
        main = "real-icons",
        -- Left on "auto" on purpose: do NOT force backend = "kitty" here.
        --
        -- Over SSH, detection cannot see Ghostty (ssh forwards TERM but not
        -- TERM_PROGRAM or GHOSTTY_RESOURCES_DIR), so forcing the backend is
        -- tempting -- but real-icons transmits images with the Kitty
        -- protocol's t=f medium, which sends the PNG's path for the terminal
        -- to open. Across an SSH boundary that path does not exist, so
        -- forcing on its own only trades a working glyph for an invisible
        -- placeholder.
        --
        -- plugin/moon.lua replaces the upload with a chunked t=d transmit in
        -- SSH sessions and forces the backend only once that has succeeded.
        opts = { backend = "auto" },
      },

      -- Glyph fallback -- left commented out on purpose.
      --
      -- real-icons draws the real image, so this is not needed to see the
      -- moon icon. What it changes is what you get when real-icons CANNOT
      -- draw an image: in a terminal with no graphics protocol, or with
      -- `magick` missing, real-icons falls back to a glyph provider. With
      -- this commented out and no other icon plugin installed, there is no
      -- provider to fall back to and .mn files show Neovim's plain default
      -- file icon.
      --
      -- Uncomment to get a moon glyph in that situation. plugin/moon.lua
      -- registers it for you as soon as the plugin is present -- nothing
      -- else to configure. (If some other plugin already pulls in
      -- nvim-web-devicons, leave this commented: it is installed anyway and
      -- the glyph is registered regardless.)
      -- "nvim-tree/nvim-web-devicons",
    },
  },
}
'@
Set-Content -LiteralPath $SpecDest -Value $specTemplate -Encoding utf8
Write-Info "Installed plugin spec → $SpecDest"

# ---------------------------------------------------------------------------
# 6. Verify (headless Neovim)
# ---------------------------------------------------------------------------
if (Test-Command 'nvim')
{
  Write-Info "Verifying with headless Neovim…"
  $tmpMoon = Join-Path $env:TEMP 'moon-verify.mn'
  @'
fn main() {
  let name = "world"
  println("hello ${name}")  /* nested /* comment */ ok */
}
'@ | Set-Content -LiteralPath $tmpMoon -Encoding utf8

  # Neovim accepts forward slashes on Windows; use them to avoid escaping issues
  # in the `set rtp^=` ex-command. Prepend (^=) so the freshly installed dir wins
  # over any stale parser in nvim-data/site — matching a real session, where the
  # config dir sits near the front of runtimepath.
  $rtp = ($NvimDir -replace '\\', '/')
  $luaVerify = @'
lua
        local ok, parser = pcall(vim.treesitter.get_parser, 0, 'moon')
        assert(ok and parser, 'tree-sitter parser for moon failed to load')
        local tree = parser:parse()[1]
        assert(not tree:root():has_error(), 'parser produced ERROR/MISSING nodes on the sample')
        local has_cfg = pcall(function() return vim.lsp.config.moon ~= nil end)
        io.stdout:write('VERIFY_OK ts=loaded lsp=' .. tostring(has_cfg) .. '\n')
'@

  $nvimArgs = @(
    '--headless', '-u', 'NONE',
    '--cmd', "set rtp^=$rtp",
    '-c', "lua vim.cmd('runtime! ftdetect/moon.vim'); vim.cmd('runtime! plugin/moon.lua')",
    '-c', "edit $tmpMoon",
    '-c', $luaVerify,
    '-c', 'qa!'
  )
  $output = & nvim @nvimArgs 2>&1 | Out-String
  if ($output -match 'VERIFY_OK')
  {
    Write-Info "Verification passed: parser loads, sample parses cleanly, LSP registered."
  } else
  {
    Write-Warn "Headless verification did not confirm cleanly. Details:"
    ($output -split "`n") | ForEach-Object { if ($_.Trim())
      { Write-Host "    $_" 
      } }
    Write-Warn "The install still completed; open a .mn file to check manually."
  }
  Remove-Item -LiteralPath $tmpMoon -Force -ErrorAction SilentlyContinue
} else
{
  Write-Warn "nvim not found on PATH — skipped verification (install still completed)."
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "moon support installed." -ForegroundColor Green
Write-Host ""
Write-Host "  Config dir : $NvimDir"
Write-Host "  LSP server : moon lsp   ($MoonBin)"
Write-Host "  Parser     : $ParserDest"
Write-Host "  Queries    : $QueryDest\"
Write-Host ""
Write-Host "Open any *.mn file in Neovim. You get syntax highlighting"
Write-Host "(tree-sitter) plus diagnostics, hover, go-to-definition, completion,"
Write-Host "references, rename, and formatting from the built-in language server."
Write-Host ""
Write-Host "To remove: pwsh -File editors/nvim/setup.ps1 -Uninstall"
