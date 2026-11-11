# moon for Neovim

Neovim support for the moon language, as a [lazy.nvim][lazy] plugin: filetype
detection for `*.mn`, the `moon lsp` language server, tree-sitter highlighting
and the moon file icon.

This directory is published as
[`moonlang-dev/moon-nvim`](https://github.com/moonlang-dev/moon-nvim), together
with the tree-sitter grammar the plugin compiles.

Requirements:

- Neovim 0.11+ for the built-in LSP client. On 0.9 and 0.10 the server starts
  through [`nvim-lspconfig`][lspconfig] when that is installed.
- The `moon` toolchain on your `PATH`, or `cmd` set to its absolute path.
- A C compiler (`$CC`, `cc`, `gcc`, `clang` or `zig cc`) to build the parser.
  Without one everything but highlighting works.
- Optionally [`real-icons.nvim`][real-icons] or [`nvim-web-devicons`][devicons]
  for the `.mn` file icon (see [File icon](#file-icon)).

## Install

```lua
{ "moonlang-dev/moon-nvim" }
```

lazy.nvim runs the plugin's `build.lua` on install and on every update, which
compiles the grammar into `parser/moon.so` and copies its queries to
`queries/moon/`, both inside the plugin's directory. Open any `*.mn` file:
highlighting and the language server attach by themselves.

`:MoonBuild` builds the parser again, and `:checkhealth moon` reports what is
missing. From a checkout of the moon repository, use the directory in place:

```lua
{ dir = "/path/to/moon/editors/nvim", name = "moon-nvim" }
```

lazy.nvim does not build a local plugin, so run `:MoonBuild` once.

With another plugin manager, or none, put this directory on the `runtimepath`
and run `:MoonBuild`.

## Options

The plugin sets itself up with these defaults. Pass `opts` to change them:

```lua
{
  "moonlang-dev/moon-nvim",
  opts = {
    cmd = { "moon", "lsp" }, -- the language server command
    lsp = true,              -- false: start no client; a table: merged into its config
    highlight = true,        -- false: leave tree-sitter highlighting off
    icon = true,             -- false: register no file icon
  },
}
```

A table in `lsp` takes anything `vim.lsp.config` does, such as `settings`,
`capabilities` or `on_attach`:

```lua
opts = {
  cmd = { "/path/to/moon/zig-out/bin/moon", "lsp" },
  lsp = { settings = { moon = { inlayHints = { parameters = false } } } },
}
```

Outside lazy.nvim, `require("moon").setup({ ... })` takes the same table.

## Language server

Run `:LspLog` and search for
`moon-lsp executable=<absolute path> version=<version>` to verify the process
Neovim launched. `:checkhealth vim.lsp` shows attachment/configuration problems;
the provenance line itself is server stderr and does not require protocol
tracing.

The server provides negotiated pull diagnostics (with legacy push fallback),
document symbols, definition/type-definition
and implementation navigation, hover, scope-aware highlights, folding,
selection ranges, and resolved import/dependency links out of the box;
references, rename, typed/snippet completion with lazy documentation, and
inferred type/generic/parameter inlay hints activate automatically as the server
advertises those capabilities. Hint categories can be disabled with
`settings = { moon = { inlayHints = { types = false, parameters = false,
generics = false } } }` in the LSP setup. Formatting activates automatically as
well. Once
formatting is available, `:lua vim.lsp.buf.format()` (or a `BufWritePre`
autocmd) formats the buffer. Range formatting is AST-bounded: the server edits
only the smallest complete safe moon node covering the range and declines an
unsafe partial construct. It also exposes indentation-only newline/`}` on-type
formatting to Neovim versions or plugins that request it.

On clients that request them, full semantic tokens refine tree-sitter syntax
with scope/type roles (including shadowing, generics, methods, enum members,
async/readonly symbols, stdlib calls, and string interpolations). Tree-sitter
continues to provide immediate syntax highlighting while semantic analysis is
unavailable or the buffer is incomplete.

Call hierarchy uses moon's resolved workspace call graph (including recursion,
closures, imports, methods, and conservatively labelled interface dispatch).
Type hierarchy shows explicit interface implementations and named aliases; use
the corresponding `vim.lsp.buf` hierarchy commands when provided by the Neovim
version in use.

Long references, workspace symbols/diagnostics, semantic tokens, and call/type
hierarchy requests honor Neovim's cancellation plus client-supplied work-done
and partial-result tokens. Ordinary hover and completion do not create progress
notifications.

Neovim's workspace folders remain independent even when projects reuse module
filenames. Watched moon/package files refresh the affected project's analysis;
LSP-aware file-rename plugins can apply the server's import edits before moving
a module.

## File icon

`.mn` files can carry the moon mark (the same logo the other editors use). The
mark is a single-colour silhouette, so it ships in two inks and `'background'`
picks between them: [`moon.png`](./moon.png) is near-black for a light
background, [`moon-dark.png`](./moon-dark.png) is white for a dark one. A
colorscheme change re-reads the option, so the image follows it.

Two providers are supported, in preference order:

| Provider | Draws | Needs |
| -------- | ----- | ----- |
| [`real-icons.nvim`][real-icons] | the real image | Kitty or Ghostty (a terminal graphics protocol) and ImageMagick's `magick` |
| [`nvim-web-devicons`][devicons] | a moon **glyph** in the mark's colour | a Nerd Font |

The plugin registers both when they are installed, and neither is required —
with no icon plugin at all, `.mn` files just get Neovim's default file icon.
Registering the glyph as well as the image is deliberate: real-icons falls back
to `nvim-web-devicons` by itself on terminals without graphics support, so the
glyph is what that fallback ends up showing.

List the provider you want as a dependency:

```lua
{
  "moonlang-dev/moon-nvim",
  dependencies = {
    -- `build` fetches the icon pack real-icons draws everything else from.
    { "Mirsmog/real-icons.nvim", build = ":RealIcons install", opts = { backend = "auto" } },
    -- "nvim-tree/nvim-web-devicons",
  },
}
```

### Integrations

real-icons ships all of its integrations disabled. The plugin turns on each one
whose host plugin is actually installed — `bufferline`, `fzf_lua`, `lualine`,
`mini_files`, `neo_tree`, `nvim_tree`, `oil`, `snacks_picker`, `telescope`, and
`telescope_file_browser` — so the mark shows up in whichever tree, picker, or
tabline you already use. Detection is a runtime-path probe rather than a
`require`, so a lazily loaded plugin is not dragged in at startup; plugins that
load later are picked up on lazy.nvim's `LazyLoad` event.

### Scope: only `.mn` gets an image

real-icons replaces *every* file icon in whichever integration it is enabled
for. That is more than a language integration should take over, so by default
only files that resolve to the moon mark are drawn as images; everything else
keeps the Nerd Font glyph it had.

`M.segment` and `M.render` both gate on `opts.image ~= false`, so asking for
`image = false` on anything that is not the moon mark falls through to
`icon.fallback` -- the glyph real-icons already resolves from `mini.icons` or
`nvim-web-devicons`. One hook there covers every integration at once, since
they all render through that module.

```lua
init = function()
  vim.g.moon_icon_only = false   -- images for everything; the default is .mn only
end,
```

Note this also applies to `:lua require("real-icons").demo()`, which shows
glyphs rather than images while it is on.

### neo-tree

neo-tree flattens `default_component_configs` into a fresh per-component table
and the renderer reads that copy, so real-icons' post-hoc patch of the original
never reaches it. Two details make this unfixable by re-running `setup()`:

- neo-tree 3.x merges lazily, but `hijack_netrw_behavior` forces the merge
  during its own `setup()` -- long before `plugin/` files are sourced.
- the merge does `for k, v in pairs(global_config)` and then
  `for k, v in pairs(component)`, so the component wins. On a second pass the
  component *is* the previously flattened table, whose stale `provider`
  overwrites the patched global every time.

So the plugin writes the provider straight into the flattened tables instead.
Set `vim.g.moon_icon_neotree_refresh = false` to leave neo-tree alone; then name
the provider in your own neo-tree spec, which is ordering-proof because
`dependencies` resolves real-icons first:

```lua
{
  "nvim-neo-tree/neo-tree.nvim",
  dependencies = { "Mirsmog/real-icons.nvim" },
  opts = {
    default_component_configs = {
      icon = {
        provider = require("real-icons.integrations.neo_tree").provider,
        use_filtered_colors = false,
      },
    },
  },
}
```

Worth knowing: neo-tree ships its own default icon provider that calls
`pcall(require, "nvim-web-devicons")` and falls back to `config.default` (`*`)
when that is missing. A `*` in the tree means that provider ran, not
real-icons'.

### Over SSH

Two separate things break when Neovim runs on a remote host, and fixing only
the first makes the symptom worse rather than better.

**Detection.** real-icons identifies Ghostty from `TERM_PROGRAM`,
`GHOSTTY_RESOURCES_DIR` or `GHOSTTY_BIN_DIR`. `ssh` sends `TERM` in the pty
request, but any other variable needs a matching `SendEnv`/`AcceptEnv` pair, so
none of those three arrive and detection reports no supported terminal.

**Transport.** real-icons uploads with the Kitty graphics protocol's `t=f`
medium — the payload is the PNG's *path*, and the terminal opens that file
itself (`backend/kitty.lua` never reads the image). That assumes the terminal
and Neovim share a filesystem. Over SSH the terminal is handed a path that
exists only on the remote and draws nothing, and `q=2` in the control string
suppresses the error reply, so `upload()` returns a valid image id and nothing
anywhere records a failure.

So forcing `backend = "kitty"` on its own does not help: it overrides a correct
"unsupported" verdict and trades a working glyph for an invisible placeholder.

The plugin fixes the transport first. In an SSH session it replaces
`backend.upload` with a chunked `t=d` transmit, which carries the image bytes
inline and works across the boundary, and only once that has succeeded does it
force the backend — using `TERM`, the one signal that does survive:

```lua
local term = (vim.env.TERM or ""):lower()
local kitty_graphics = term:find("ghostty", 1, true) or term:find("kitty", 1, true)
if kitty_graphics and icons_config.options.backend == "auto" then
  icons_config.options.backend = "kitty"
end
```

Local sessions are left completely alone — upstream's `t=f` is cheaper there,
since it does not push the whole image through the pty as base64.

This is a monkey-patch of another plugin's internals, so it checks the shape of
`upload`, `image_id`, `wrap_for_tmux` and `clear_uploaded` first and does
nothing if any of them has changed. It also wraps `clear_uploaded`, because
upstream only deletes image ids it uploaded itself. Delete the section from
`lua/moon/icon.lua` if upstream ever transmits with `t=d` on its own.

To see what a session actually resolved:

```vim
:checkhealth real-icons
:lua vim.print(require("real-icons.backend.kitty").detect({ refresh = true }))
:lua require("real-icons").demo()
```

`demo()` renders straight through the resolver, so a blank demo rules the
tree/picker integrations out and points at the terminal or transport instead.

### Another image

`vim.g.moon_icon_path` names an image to use in place of the two the plugin
ships. One path serves both backgrounds, so name the ink your colorscheme
wants:

```lua
vim.g.moon_icon_path = "/path/to/moon-dark.png"
```

`real-icons.setup()` rebuilds every option from the plugin defaults, so it
discards an override written by anything that ran before it. That is why the
plugin writes into the live options table instead of calling `setup()`, and
re-applies on `VimEnter`.

## Installer scripts

`setup.sh` and `setup.ps1` are the other way in: they copy a plugin-free setup
(the parser, the queries, a filetype rule and a `plugin/moon.lua`) into your
Neovim config directory, building the toolchain first when run from the moon
repository. The `moon-neovim.zip` asset of the rolling `editors` release at
[`moonlang-dev/moon-releases`](https://github.com/moonlang-dev/moon-releases)
carries them with the grammar.

```sh
./setup.sh          # install; re-run to refresh
./setup.sh --help   # options (--rebuild, --config-dir, --uninstall)
```

```powershell
pwsh -File setup.ps1          # install; re-run to refresh
pwsh -File setup.ps1 -Help    # options (-Rebuild, -ConfigDir, -Uninstall)
```

The Windows script compiles the parser with `zig cc`. Both write a lazy.nvim
spec to `lua/plugins/moon.lua` that lists the icon providers. Use one of the
two: with the plugin installed as well, the plugin loads and the installed
`plugin/moon.lua` stands down.

[lazy]: https://github.com/folke/lazy.nvim
[lspconfig]: https://github.com/neovim/nvim-lspconfig
[real-icons]: https://github.com/Mirsmog/real-icons.nvim
[devicons]: https://github.com/nvim-tree/nvim-web-devicons
