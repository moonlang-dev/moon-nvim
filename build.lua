-- lazy.nvim runs this file when the plugin is installed or updated.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
package.loaded["moon.build"] = nil

local ok, err = require("moon.build").run({ notify = false })
if not ok then
  error(err, 0)
end
