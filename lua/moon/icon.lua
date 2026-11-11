-- The moon mark on .mn files in trees and pickers.
--
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
--
-- The mark is a single-colour silhouette, so it ships in two inks: moon.png is
-- near-black for a light background and moon-dark.png is white for a dark one.
-- 'background' picks between them, and is re-read whenever it changes.
--
-- vim.g.moon_icon_path names another image; it is used as given, for both
-- backgrounds.
local M = {}

local moon_icon_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function resolve_moon_icon()
  if vim.g.moon_icon_path then
    return vim.fn.expand(vim.g.moon_icon_path)
  end
  local ink = vim.o.background == "dark" and "moon-dark.png" or "moon.png"
  return moon_icon_dir .. "/" .. ink
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

local registered = false

--- Registers the icon with the providers present, now and as they load.
function M.setup()
  register_moon_icon()
  if registered then
    return
  end
  registered = true

  -- Re-apply after startup. Three reasons: a plugin manager may load either
  -- provider after this runs, real-icons' setup() rebuilds its options from
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
end

return M
