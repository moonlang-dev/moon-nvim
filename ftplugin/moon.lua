vim.bo.commentstring = "// %s"
vim.bo.comments = ":///,://"
vim.b.undo_ftplugin = (vim.b.undo_ftplugin and vim.b.undo_ftplugin .. " | " or "")
  .. "setlocal commentstring< comments<"

require("moon").highlight(0)
