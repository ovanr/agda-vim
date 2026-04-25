local M = require('agda-mode').setup()

-- Only do this once per buffer
if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = 1

-- Collect undo steps (matches Vim's b:undo_ftplugin convention)
local undo = {}

local function add_undo(cmd)
  table.insert(undo, cmd)
end

local function reload_syntax()
  vim.cmd.syntax("clear")

  -- Source per-file syntax overrides: %:h . "/." . %:t . ".vim"
  local dir = vim.fn.expand("%:h")
  local tail = vim.fn.expand("%:t")
  local f = dir .. "/." .. tail .. ".vim"

  if vim.fn.filereadable(f) == 1 then
    vim.cmd("source " .. vim.fn.fnameescape(f))
  end

  vim.cmd.runtime("syntax/agda.vim")
end

-- -------------------------
-- __Agda__ log buffer (port of s:LogAgda)
-- -------------------------
local function log_agda(name, text, append)
  local agda_bufnr = vim.fn.bufnr("__Agda__")
  local agda_winnr = vim.fn.bufwinnr("__Agda__") -- -1 if not visible
  local prev_win = vim.api.nvim_get_current_win()

  if agda_winnr == -1 then
    -- open split (botright 8split __Agda__)
    vim.cmd("silent keepalt botright 8split __Agda__")
    agda_bufnr = vim.api.nvim_get_current_buf()

    -- set buffer/window options
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "hide"
    vim.bo.swapfile = false
    vim.bo.buflisted = false
    vim.wo.list = false
    vim.wo.number = false
    vim.wo.wrap = false
    vim.bo.textwidth = 0
    vim.wo.cursorline = false
    vim.wo.cursorcolumn = false
    pcall(function() vim.wo.relativenumber = false end)
  else
    -- jump to existing window
    vim.cmd(agda_winnr .. "wincmd w")
    agda_bufnr = vim.api.nvim_get_current_buf()
  end

  -- Set statusline title
  vim.wo.statusline = name or "__Agda__"

  -- Replace/append content
  vim.bo.modifiable = true
  if tostring(append) == "True" then
    vim.api.nvim_buf_set_lines(agda_bufnr, -1, -1, true, vim.split(text or "", "\n", { plain = true }))
  else
    vim.api.nvim_buf_set_lines(agda_bufnr, 0, -1, true, vim.split(text or "", "\n", { plain = true }))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end
  vim.bo.modifiable = false

  -- Go back
  vim.api.nvim_set_current_win(prev_win)
end

-- If you want your Lua backend to use this logger,
-- you can read this function from vim.g in your backend.
vim.g.agdavim_log_agda = log_agda

-- -------------------------
-- Autocmd: QuickfixCmdPost make
-- -------------------------
local aug = vim.api.nvim_create_augroup("agdavim_ftplugin_" .. vim.api.nvim_get_current_buf(), { clear = true })

vim.api.nvim_create_autocmd("QuickfixCmdPost", {
  group = aug,
  callback = function()
    reload_syntax()

    -- Quiet version/load like: call AgdaVersion(v:true)|call AgdaLoad(v:true)
    M.AgdaVersion({ quiet = true })
    M.AgdaLoad({ quiet = true })
  end,
  buffer = 0,
})

-- -------------------------
-- Buffer-local options
-- -------------------------
vim.opt_local.autowrite = true
add_undo("setlocal autowrite<")

-- include path list (NOTE: keep these as *raw* paths; quote only for makeprg)
local extra = vim.g.agda_extraincpaths or {}
vim.g.agdavim_agda_includepathlist = vim.list_extend({ "." }, vim.deepcopy(extra))

-- makeprg: agda --vim -i p1 -i p2 %
local inc = {}
for _, p in ipairs(vim.g.agdavim_agda_includepathlist) do
  table.insert(inc, "-i " .. vim.fn.shellescape(p))
end
vim.opt_local.makeprg = "agda --vim " .. table.concat(inc, " ") .. " %"
add_undo("setlocal makeprg<")

if vim.g.agdavim_includeutf8_mappings == nil or vim.g.agdavim_includeutf8_mappings == true then
  vim.cmd("runtime agda-utf8.vim")
end

vim.g.agdavim_enable_goto_definition = (vim.g.agdavim_enable_goto_definition == nil) and true
  or not not vim.g.agdavim_enable_goto_definition

vim.opt_local.errorformat =
  [[  /%\\&%f:%l\\,%c-%.%#,%E/%\\&%f:%l\\,%c-%.%#,%Z,%C%m,%-G%.%#]]
add_undo("setlocal errorformat<")

vim.opt_local.lisp = false
add_undo("setlocal lisp<")

-- formatoptions: remove 't', add 'croql'
vim.opt_local.formatoptions:remove("t")
vim.opt_local.formatoptions:append({ "c", "r", "o", "q", "l" })
add_undo("setlocal formatoptions<")

vim.opt_local.autoindent = true
add_undo("setlocal autoindent<")

-- Comments and commentstring
vim.opt_local.comments = { "sfl:{-", "mb1:--", "ex:-}", ":--" }
add_undo("setlocal comments<")

vim.opt_local.commentstring = "-- %s"
add_undo("setlocal commentstring<")

-- iskeyword
vim.opt_local.iskeyword = "@,!-~,^\\,,^\\(,^\\),^\\\",^\\',192-255"
add_undo("setlocal iskeyword<")

-- -------------------------
-- Commands
-- -------------------------
vim.api.nvim_create_user_command("AgdaReloadSyntax", function()
  reload_syntax()
end, { buffer = true })

vim.api.nvim_create_user_command("AgdaReload", function()
  vim.cmd("silent! make!")
  vim.cmd("redraw!")
end, { buffer = true })

-- Convenience buffer-local wrappers (mirrors your ftplugin commands)
vim.api.nvim_create_user_command("AgdaLoad", function()
  require("agdavim").AgdaLoad({ quiet = false })
end, { buffer = true })

vim.api.nvim_create_user_command("AgdaVersion", function()
  require("agdavim").AgdaVersion({ quiet = false })
end, { buffer = true })

-- -------------------------
-- Mappings (buffer-local)
-- -------------------------
local map = function(lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { buffer = true, silent = true, desc = desc })
end

map("<LocalLeader>l", "<Cmd>AgdaReload<CR>", "Agda reload (make)")
map("<LocalLeader>t", function() require("agdavim").AgdaInfer() end, "Agda infer")
map("<LocalLeader>r", function() require("agdavim").AgdaRefine("False") end, "Agda refine")
map("<LocalLeader>R", function() require("agdavim").AgdaRefine("True") end, "Agda refine (unfold abstract)")
map("<LocalLeader>g", function() require("agdavim").AgdaGive() end, "Agda give")
map("<LocalLeader>c", function() require("agdavim").AgdaMakeCase() end, "Agda make case")
map("<LocalLeader>a", function() require("agdavim").AgdaAuto() end, "Agda auto")
map("<LocalLeader>e", function() require("agdavim").AgdaContext() end, "Agda context")
map("<LocalLeader>n", function() require("agdavim").AgdaNormalize("IgnoreAbstract") end, "Agda normalize (ignore abstract)")
map("<LocalLeader>N", function() require("agdavim").AgdaNormalize("DefaultCompute") end, "Agda normalize (default)")
map("<LocalLeader>M", function() require("agdavim").AgdaShowModule("") end, "Agda show module")
map("<LocalLeader>y", function() require("agdavim").AgdaWhyInScope("") end, "Agda why in scope")
map("<LocalLeader>h", function() require("agdavim").AgdaHelperFunction() end, "Agda helper function")
map("<LocalLeader>d", function() require("agdavim").AgdaGotoAnnotation() end, "Agda goto definition")

-- Optional: keep this mapping only if :AgdaMetas exists (your Vimscript referred to it)
map("<LocalLeader>m", function()
  if vim.fn.exists(":AgdaMetas") == 2 then
    vim.cmd("AgdaMetas")
  else
    vim.notify("AgdaMetas command not available", vim.log.levels.WARN, { title = "agdavim" })
  end
end, "Agda metas")

-- Go to next/previous meta (search for " {!" or " ?")
local function goto_meta(flags)
  local saved = vim.fn.getreg("/")
  vim.fn.search([[ {!\| ?]], flags)
  vim.fn.setreg("/", saved)

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  vim.api.nvim_win_set_cursor(0, { row, col + 2 })
end

vim.keymap.set("n", "]m", function() goto_meta("W") end, { buffer = true, silent = true, desc = "Next meta/hole" })
vim.keymap.set("i", "[m", function()
  goto_meta("bW")
end, { buffer = true, silent = true, desc = "Prev meta/hole" })

-- -------------------------
-- Initial actions
-- -------------------------
reload_syntax()
vim.cmd("AgdaReload")

-- Finalise undo string
vim.b.undo_ftplugin = table.concat(undo, " | ")
