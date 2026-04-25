-- lua/agdavim/init.lua
local M = {}

local uv = vim.uv or vim.loop

local state = {
  handle = nil,
  stdin = nil,
  stdout = nil,
  stderr = nil,

  -- stdout line buffering
  _stdout_buf = "",
  _stdout_q = {},

  goals = {},         -- key: "row:bytecol" -> goalId
  annotations = {},   -- { {loByte, hiByte, file, posByte}, ... }

  agda_version = { 0, 0, 0, 0 },
  rewriteMode = "Normalised",

  busy = false,
}

-- -------------------------
-- small utilities
-- -------------------------

local function startswith(s, prefix)
  return s:sub(1, #prefix) == prefix
end

local function trim_nl(s)
  return (s:gsub("\r?\n$", ""))
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "agdavim" })
end

local function vim_bool(x)
  if x == nil or x == "" then return false end
  if x == false then return false end
  if x == true then return true end
  if x == "False" then return false end
  if x == "True" then return true end
  local n = tonumber(x)
  if n ~= nil then return n ~= 0 end
  return true
end

-- "cheating" escape/unescape (kept from your Python)
local function escape_hs(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  return s
end

local function unescape_hs(s)
  -- matches your hack: \\\\ -> \x00, then restore later
  s = s:gsub("\\\\", "\0")
  s = s:gsub('\\"', '"')
  s = s:gsub("\\n", "\n")
  s = s:gsub("\0", "\\")
  return s
end

-- robust-ish "find quoted strings with backslash escapes"
local function extract_quoted_strings(s)
  local out = {}
  local i = 1
  while i <= #s do
    local q = s:find('"', i, true)
    if not q then break end
    i = q + 1
    local buf = {}
    while i <= #s do
      local c = s:sub(i, i)
      if c == "\\" then
        local nxt = s:sub(i + 1, i + 1)
        if nxt == "" then break end
        table.insert(buf, "\\" .. nxt)
        i = i + 2
      elseif c == '"' then
        table.insert(out, table.concat(buf))
        i = i + 1
        break
      else
        table.insert(buf, c)
        i = i + 1
      end
    end
  end
  return out
end

local function parse_version(version_string)
  -- expects "*Agda Version*" payload like "Agda version 2.6.4.1" (etc.)
  local tail = version_string:sub(13) -- after "Agda version "
  tail = tail:match("^([^%-]+)") or tail
  local nums = {}
  for n in tail:gmatch("(%d+)") do
    table.insert(nums, tonumber(n))
  end
  while #nums < 4 do table.insert(nums, 0) end
  state.agda_version = { nums[1] or 0, nums[2] or 0, nums[3] or 0, nums[4] or 0 }
end

local function version_lt(a, b)
  for i = 1, 4 do
    local ai, bi = a[i] or 0, b[i] or 0
    if ai < bi then return true end
    if ai > bi then return false end
  end
  return false
end

local function ensure_list(x)
  if type(x) == "table" then return x end
  return {}
end

-- -------------------------
-- Agda process management
-- -------------------------

local function _push_stdout_data(data)
  if not data or data == "" then return end
  state._stdout_buf = state._stdout_buf .. data
  while true do
    local nl = state._stdout_buf:find("\n", 1, true)
    if not nl then break end
    local line = state._stdout_buf:sub(1, nl)
    state._stdout_buf = state._stdout_buf:sub(nl + 1)
    table.insert(state._stdout_q, line)
  end
end

local function start_agda()
  if state.handle and not state.handle:is_closing() then
    return true
  end

  state.stdin = uv.new_pipe(false)
  state.stdout = uv.new_pipe(false)
  state.stderr = uv.new_pipe(false)

  local handle, pid = uv.spawn("agda", {
    args = { "--interaction" },
    stdio = { state.stdin, state.stdout, state.stderr },
  }, function()
    -- exit callback
    if state.stdout and not state.stdout:is_closing() then state.stdout:close() end
    if state.stderr and not state.stderr:is_closing() then state.stderr:close() end
    if state.stdin and not state.stdin:is_closing() then state.stdin:close() end
    state.handle = nil
  end)

  if not handle then
    notify("Failed to start `agda --interaction` (is Agda in PATH?)", vim.log.levels.ERROR)
    return false
  end

  state.handle = handle
  state._stdout_buf = ""
  state._stdout_q = {}

  state.stdout:read_start(function(err, data)
    if err then return end
    _push_stdout_data(data)
  end)

  state.stderr:read_start(function(_, _) end)

  notify(("Agda started (pid %s)"):format(pid))
  return true
end

function M.AgdaRestart()
  if state.handle and not state.handle:is_closing() then
    state.handle:kill("sigterm")
  end
  state.handle = nil
  start_agda()
end

-- -------------------------
-- buffer/pos helpers
-- -------------------------

local function linec2b(row, n)
  -- byteidx(getline(row), n)
  return tonumber(vim.fn.byteidx(vim.fn.getline(row), n)) or 0
end

local function c2b(n)
  -- byteidx(join(getline(1,"$"),"\n"), n)
  local blob = table.concat(vim.fn.getline(1, "$"), "\n")
  return tonumber(vim.fn.byteidx(blob, n)) or 0
end

local function key_row_col(row, bcol)
  return ("%d:%d"):format(row, bcol)
end

local function find_goal(row, bcol)
  return state.goals[key_row_col(row, bcol)]
end

local function prompt_user(msg)
  return vim.fn.input(msg)
end

-- -------------------------
-- goals + annotations
-- -------------------------

local function find_goals(goal_list)
  -- goal_list is an array of goal numbers
  vim.cmd("syn sync fromstart")

  state.goals = {}
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
  local hole_hl = vim.fn.hlID("agdaHole")

  local remaining = vim.deepcopy(goal_list)
  for row, line in ipairs(lines) do
    local start = 0
    while start ~= -1 do
      local qstart = line:find("?", start + 1, true)
      local hstart = line:find("{!", start + 1, true)

      if not qstart then
        start = hstart and (hstart - 1) or -1
      elseif not hstart then
        start = qstart - 1
      else
        start = math.min(qstart - 1, hstart - 1)
      end

      if start ~= -1 then
        start = start + 1 -- match the Python logic
        local bcol = linec2b(row, start)

        local syn_id = vim.fn.synID(row, bcol, 0)
        if syn_id == hole_hl then
          local goal = table.remove(remaining, 1)
          if goal then
            state.goals[key_row_col(row, bcol)] = goal
          end
        end
      end

      if #remaining == 0 then break end
    end
    if #remaining == 0 then break end
  end

  vim.cmd("syn sync clear")
end

local function parse_annotation(spans)
  -- Port of Python regex:
  -- \((\d+) (\d+) \([^\)]*\) \w+ \w+ \(\"([^"]*)\" \. (\d+)\)\)
  local pat = [[\v\((\d+) (\d+) \([^)]*\) \w+ \w+ \("([^"]*)" \. (\d+)\)\)]]
  local idx = 0
  while true do
    local m = vim.fn.matchstrpos(spans, pat, idx)
    local s = m[2]
    local e = m[3]
    if s == -1 then break end

    local sub = spans:sub(s + 1)
    local caps = vim.fn.matchlist(sub, pat)
    -- caps: [0]=full, [1]=start, [2]=end, [3]=file, [4]=pos
    local a0 = tonumber(caps[2] or "")
    local a1 = tonumber(caps[3] or "")
    local file = caps[4] or ""
    local pos = tonumber(caps[5] or "")

    if a0 and a1 and pos then
      table.insert(state.annotations, { c2b(a0 - 1), c2b(a1 - 1), file, c2b(pos) })
    end

    idx = e
  end
end

local function search_annotation(lo, hi, idx)
  if hi == 0 then return nil end

  while hi - lo > 1 do
    local mid = lo + math.floor((hi - lo) / 2)
    local mid_offset = state.annotations[mid + 1][1] -- Lua 1-based
    if idx < mid_offset then
      hi = mid
    else
      lo = mid
    end
  end

  local ann = state.annotations[lo + 1]
  local loOffset, hiOffset = ann[1], ann[2]
  if idx > loOffset and idx <= hiOffset then
    return { ann[3], ann[4] }
  end
  return nil
end

function M.AgdaGotoAnnotation()
  local byteOffset = tonumber(vim.fn.line2byte(vim.fn.line(".")) + vim.fn.col(".") - 1) or 0
  local res = search_annotation(0, #state.annotations, byteOffset)
  if not res then return end
  local file, pos = res[1], res[2]

  local target_buf = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name == file then
      target_buf = b
      break
    end
  end

  if not target_buf then
    vim.cmd.edit(vim.fn.fnameescape(file))
  else
    vim.api.nvim_set_current_buf(target_buf)
  end
  vim.cmd(("%dgo"):format(pos))
end

-- -------------------------
-- hole operations
-- -------------------------

local function replace_hole(replacement)
  local rep = replacement:gsub("\n", " "):gsub("    ", ";")
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0)) -- col0 is 0-based
  local line = vim.api.nvim_get_current_line()

  local ch = line:sub(col0 + 1, col0 + 1)
  local start_col, end_col

  if ch == "?" then
    start_col = col0
    end_col = col0 + 1
  else
    start_col = -1
    local nextMatch = vim.fn.match(line, "{!")
    while nextMatch ~= -1 do
      start_col = nextMatch
      nextMatch = vim.fn.match(line, "{!", start_col + 1)
    end
    end_col = vim.fn.matchend(line, "!}", vim.fn.col(".") - 2)
  end

  if start_col == -1 or end_col == -1 then return end

  local before = (start_col == 0) and "" or line:sub(1, start_col)
  local after = line:sub(end_col + 1)
  vim.api.nvim_set_current_line(before .. rep .. after)

  -- keep cursor roughly in place
  vim.api.nvim_win_set_cursor(0, { row, math.min(#(before .. rep), col0) })
end

local function get_hole_body_at_cursor()
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local ch = line:sub(col0 + 1, col0 + 1)

  if ch == "?" then
    -- Python used findGoal(r, c+1)
    local goal = find_goal(row, col0 + 1)
    return { "?", goal }
  end

  local start = -1
  local nextMatch = vim.fn.matchend(line, "{!")
  while nextMatch ~= -1 do
    start = nextMatch
    nextMatch = vim.fn.matchend(line, "{!", start)
  end
  local end_ = vim.fn.match(line, "!}", vim.fn.col(".") - 2)

  if start == -1 or end_ == -1 then return nil end

  local body = line:sub(start + 1, end_):gsub("^%s+", ""):gsub("%s+$", "")
  if body == "" then body = "?" end

  local goal = find_goal(row, start - 1)
  return { body, goal }
end

local function get_word_at_cursor()
  return (vim.fn.expand("<cWORD>") or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- -------------------------
-- Agda I/O protocol
-- -------------------------

local function pop_stdout_line()
  if #state._stdout_q == 0 then return nil end
  return table.remove(state._stdout_q, 1)
end

local function get_output_block(timeout_ms)
  timeout_ms = timeout_ms or 10000

  local responses = {}

  local function done()
    -- we stop once we see "Agda2> cannot read" (your sentinel)
    for i = #responses, 1, -1 do
      local s = responses[i]
      if startswith(s, "Agda2> cannot read") then
        return true
      end
    end
    return false
  end

  local ok = vim.wait(timeout_ms, function()
    -- drain queue
    while true do
      local line = pop_stdout_line()
      if not line then break end
      line = trim_nl(line)

      -- strip interactive prompt when present
      if startswith(line, "Agda2> ") then
        line = line:sub(8)
      end

      table.insert(responses, line)
      if startswith(line, "Agda2> cannot read") then
        return true
      end
    end
    return done()
  end, 10)

  if not ok then
    notify("Timed out waiting for Agda output", vim.log.levels.WARN)
  end

  return responses
end

local function set_rewrite_mode(mode)
  mode = (mode or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local allowed = {
    AsIs = true,
    Normalised = true,
    Simplified = true,
    HeadNormal = true,
    Instantiated = true,
  }
  state.rewriteMode = allowed[mode] and mode or "Normalised"
end

local function log_agda(title, msg, is_error)
  local level = is_error and vim.log.levels.ERROR or vim.log.levels.INFO
  notify(("%s: %s"):format(title, msg), level)
end

local function interpret_response(responses, quiet)
  quiet = vim_bool(quiet)

  for _, response in ipairs(responses) do
    if startswith(response, "(agda2-info-action ") or startswith(response, "(agda2-info-action-and-copy ") then
      if quiet and response:find("%*Error%*", 1, true) then
        vim.cmd("cwindow")
      end

      local payload = response:sub(20) -- roughly matches python's [19:], keep close enough
      local strings = extract_quoted_strings(payload)
      if strings[1] == "*Agda Version*" and strings[2] then
        parse_version(unescape_hs(strings[2]))
      end

      if not quiet and strings[1] and strings[2] then
        log_agda(unescape_hs(strings[1]), unescape_hs(strings[2]), response:sub(-2) == "t)")
      end

    elseif response:find("%(agda2%-goals%-action '", 1) then
      local nums = {}
      for n in response:gmatch("(%d+)") do
        table.insert(nums, tonumber(n))
      end
      find_goals(nums)

    elseif response:find("%(agda2%-make%-case%-action%-extendlam '", 1) then
      -- same replacement hack
      response = response:gsub("%?", "{!   !}")
      local tail = response:match("agda2%-make%-case%-action%-extendlam '.+$") or response
      local cases = extract_quoted_strings(tail)

      local _, col0 = unpack(vim.api.nvim_win_get_cursor(0))
      local line = vim.api.nvim_get_current_line()

      -- heuristic port of Python logic
      local correction = 0
      local starts = {}
      for m in line:sub(1, col0):gmatch("()%;") do
        table.insert(starts, m)
      end
      if #starts == 0 then
        correction = 1
        for m in line:sub(1, col0):gmatch("(){[^!]") do
          table.insert(starts, m)
        end
        if #starts == 0 then
          correction = 1
          -- indentation start
          local s = (line:match("^()%s*") or 1)
          table.insert(starts, s)
        end
      end
      local start_pos = (starts[#starts] or 1) - correction

      correction = 0
      local rest = line:sub(col0 + 1)
      local end_pos
      local semi = rest:find(";", 1, true)
      if semi then
        end_pos = col0 + semi - 1
      else
        correction = 1
        local br = rest:find("[^!}%]]", 1) -- not perfect but mirrors your intent
        if br then
          end_pos = col0 + br - 1 + correction
        else
          local trailing = rest:find("%s*$")
          end_pos = col0 + (trailing or #rest)
        end
      end

      local joined = " " .. table.concat(vim.tbl_map(unescape_hs, cases), "; ") .. " "
      local new_line = line:sub(1, start_pos) .. joined .. line:sub(end_pos + 1)
      vim.api.nvim_set_current_line(new_line)

      M.AgdaLoad({ quiet = quiet })
      break

    elseif response:find("%(agda2%-make%-case%-action '", 1) then
      response = response:gsub("%?", "{!   !}")
      local tail = response:match("agda2%-make%-case%-action '.+$") or response
      local cases = extract_quoted_strings(tail)

      local row = vim.api.nvim_win_get_cursor(0)[1]
      local indent = (vim.api.nvim_get_current_line():match("^[ \t]*") or "")
      local lines = {}
      for _, c in ipairs(cases) do
        table.insert(lines, indent .. unescape_hs(c))
      end
      -- insert below current line
      vim.api.nvim_buf_set_lines(0, row, row, true, lines)

      M.AgdaLoad({ quiet = quiet })
      break

    elseif startswith(response, "(agda2-give-action ") then
      response = response:gsub("%?", "{!   !}")
      local m_goal, m_expr = response:match("(%d+)%s+\"(.-)\"")
      if m_expr then
        replace_hole(unescape_hs(m_expr))
      end

    elseif startswith(response, "(agda2-highlight-add-annotations ") then
      parse_annotation(response)

    else
      -- ignore
    end
  end
end

local function send_command(arg, opts)
  opts = opts or {}
  local quiet = vim_bool(opts.quiet)
  local highlighting = vim_bool(opts.highlighting)

  if state.busy then
    notify("Agda is busy; try again in a moment", vim.log.levels.WARN)
    return
  end
  state.busy = true

  if not start_agda() then
    state.busy = false
    return
  end

  -- write buffer to disk (same as python)
  pcall(vim.cmd, "silent! write")

  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    notify("Current buffer has no file name", vim.log.levels.ERROR)
    state.busy = false
    return
  end

  local iotcm_mode = highlighting and "Interactive" or "None"
  local cmd = ('IOTCM "%s" %s Direct (%s)\n'):format(escape_hs(file), iotcm_mode, arg)
  -- sentinel trick copied from python
  cmd = cmd .. "x\n"

  state.stdin:write(cmd)

  local responses = get_output_block(20000)
  interpret_response(responses, quiet)

  state.busy = false
end

local function send_command_load_highlighting_info(file, quiet)
  send_command(('Cmd_load_highlighting_info "%s"'):format(escape_hs(file)), { quiet = quiet, highlighting = true })
end

local function send_command_load(file, quiet, highlighting)
  local inc = ensure_list(vim.g.agdavim_agda_includepathlist)
  local incpaths_str

  if version_lt(state.agda_version, { 2, 5, 0, 0 }) then
    -- old: plain comma list
    incpaths_str = table.concat(inc, ",")
  else
    -- new: "-i","p1","-i","p2",...
    local parts = {}
    for _, p in ipairs(inc) do
      table.insert(parts, '"-i"')
      table.insert(parts, ('"%s"'):format(p))
    end
    incpaths_str = table.concat(parts, ",")
  end

  if highlighting == nil then
    highlighting = vim_bool(vim.g.agdavim_enable_goto_definition)
  end

  send_command(('Cmd_load "%s" [%s]'):format(escape_hs(file), incpaths_str), {
    quiet = quiet,
    highlighting = highlighting,
  })
end

-- -------------------------
-- Exposed user functions
-- -------------------------

function M.AgdaVersion(opts)
  opts = opts or {}
  send_command("Cmd_show_version", { quiet = opts.quiet })
end

function M.AgdaLoad(opts)
  opts = opts or {}
  local f = vim.api.nvim_buf_get_name(0)
  send_command_load(f, opts.quiet)
end

function M.AgdaLoadHighlightInfo(opts)
  opts = opts or {}
  local f = vim.api.nvim_buf_get_name(0)
  send_command_load_highlighting_info(f, opts.quiet)
end

function M.AgdaGive()
  local res = get_hole_body_at_cursor()

  local useForce = ""
  if not version_lt(state.agda_version, { 2, 5, 3, 0 }) then
    useForce = "WithoutForce" -- or WithForce
  end

  if not res then
    notify("No hole under the cursor", vim.log.levels.WARN)
    return
  end
  if not res[2] then
    notify("Goal not loaded", vim.log.levels.WARN)
    return
  end

  if res[1] == "?" then
    local expr = prompt_user("Enter expression: ")
    send_command(('Cmd_give %s %d noRange "%s"'):format(useForce, res[2], escape_hs(expr)), {})
  else
    send_command(('Cmd_give %s %d noRange "%s"'):format(useForce, res[2], escape_hs(res[1])), {})
  end
end

function M.AgdaMakeCase()
  local res = get_hole_body_at_cursor()
  if not res then
    notify("No hole under the cursor", vim.log.levels.WARN)
  elseif not res[2] then
    notify("Goal not loaded", vim.log.levels.WARN)
  elseif res[1] == "?" then
    local expr = prompt_user("Make case on: ")
    send_command(('Cmd_make_case %d noRange "%s"'):format(res[2], escape_hs(expr)))
  else
    send_command(('Cmd_make_case %d noRange "%s"'):format(res[2], escape_hs(res[1])))
  end
end

function M.AgdaRefine(unfoldAbstract)
  local res = get_hole_body_at_cursor()
  if not res then
    notify("No hole under the cursor", vim.log.levels.WARN)
  elseif not res[2] then
    notify("Goal not loaded", vim.log.levels.WARN)
  else
    send_command(('Cmd_refine_or_intro %s %d noRange "%s"'):format(unfoldAbstract, res[2], escape_hs(res[1])))
  end
end

function M.AgdaAuto()
  local res = get_hole_body_at_cursor()
  if not res then
    notify("No hole under the cursor", vim.log.levels.WARN)
  elseif not res[2] then
    notify("Goal not loaded", vim.log.levels.WARN)
  else
    local arg = (res[1] ~= "?") and escape_hs(res[1]) or ""
    if version_lt(state.agda_version, { 2, 6, 0, 0 }) then
      send_command(('Cmd_auto %d noRange "%s"'):format(res[2], arg))
    else
      send_command(('Cmd_autoOne %d noRange "%s"'):format(res[2], arg))
    end
  end
end

function M.AgdaContext()
  local res = get_hole_body_at_cursor()
  if not res then
    notify("No hole under the cursor", vim.log.levels.WARN)
  elseif not res[2] then
    notify("Goal not loaded", vim.log.levels.WARN)
  else
    send_command(('Cmd_goal_type_context_infer %s %d noRange "%s"'):format(state.rewriteMode, res[2], escape_hs(res[1])))
  end
end

function M.AgdaInfer()
  local res = get_hole_body_at_cursor()
  if not res then
    local expr = prompt_user("Enter expression: ")
    send_command(('Cmd_infer_toplevel %s "%s"'):format(state.rewriteMode, escape_hs(expr)))
  elseif not res[2] then
    notify("Goal not loaded", vim.log.levels.WARN)
  else
    send_command(('Cmd_infer %s %d noRange "%s"'):format(state.rewriteMode, res[2], escape_hs(res[1])))
  end
end

function M.AgdaNormalize(unfoldAbstract)
  if version_lt(state.agda_version, { 2, 5, 2, 0 }) then
    unfoldAbstract = tostring(unfoldAbstract == "DefaultCompute")
  end

  local res = get_hole_body_at_cursor()
  if not res then
    local expr = prompt_user("Enter expression: ")
    send_command(('Cmd_compute_toplevel %s "%s"'):format(unfoldAbstract, escape_hs(expr)))
  elseif not res[2] then
    notify("Goal not loaded", vim.log.levels.WARN)
  else
    send_command(('Cmd_compute %s %d noRange "%s"'):format(unfoldAbstract, res[2], escape_hs(res[1])))
  end
end

function M.AgdaWhyInScope(termName)
  termName = termName or ""
  local res = (termName == "") and get_hole_body_at_cursor() or nil

  if not res then
    local name = (termName ~= "" and termName) or get_word_at_cursor()
    if name == "" then name = prompt_user("Enter name: ") end
    send_command(('Cmd_why_in_scope_toplevel "%s"'):format(escape_hs(name)))
  elseif not res[2] then
    notify("Goal not loaded", vim.log.levels.WARN)
  else
    send_command(('Cmd_why_in_scope %d noRange "%s"'):format(res[2], escape_hs(res[1])))
  end
end

function M.AgdaShowModule(moduleName)
  moduleName = moduleName or ""
  local res = (moduleName == "") and get_hole_body_at_cursor() or nil

  if version_lt(state.agda_version, { 2, 4, 2, 0 }) then
    if not res then
      local name = moduleName ~= "" and moduleName or prompt_user("Enter module name: ")
      send_command(('Cmd_show_module_contents_toplevel "%s"'):format(escape_hs(name)))
    elseif not res[2] then
      notify("Goal not loaded", vim.log.levels.WARN)
    else
      send_command(('Cmd_show_module_contents %d noRange "%s"'):format(res[2], escape_hs(res[1])))
    end
  else
    if not res then
      local name = moduleName ~= "" and moduleName or prompt_user("Enter module name: ")
      send_command(('Cmd_show_module_contents_toplevel %s "%s"'):format(state.rewriteMode, escape_hs(name)))
    elseif not res[2] then
      notify("Goal not loaded", vim.log.levels.WARN)
    else
      send_command(('Cmd_show_module_contents %s %d noRange "%s"'):format(state.rewriteMode, res[2], escape_hs(res[1])))
    end
  end
end

function M.AgdaHelperFunction()
  local res = get_hole_body_at_cursor()
  if not res then
    notify("No hole under the cursor", vim.log.levels.WARN)
  elseif not res[2] then
    notify("Goal not loaded", vim.log.levels.WARN)
  elseif res[1] == "?" then
    local name = prompt_user("Enter name for helper function: ")
    send_command(('Cmd_helper_function %s %d noRange "%s"'):format(state.rewriteMode, res[2], escape_hs(name)))
  else
    send_command(('Cmd_helper_function %s %d noRange "%s"'):format(state.rewriteMode, res[2], escape_hs(res[1])))
  end
end

function M.SetRewriteMode(mode)
  set_rewrite_mode(mode)
end

-- -------------------------
-- setup: commands
-- -------------------------

function M.setup()
  -- defaults (match your python expectations)
  if vim.g.agdavim_agda_includepathlist == nil then
    vim.g.agdavim_agda_includepathlist = {}
  end
  if vim.g.agdavim_enable_goto_definition == nil then
    vim.g.agdavim_enable_goto_definition = true
  end

  local function cmd_bool_bang(opts) return opts.bang end

  vim.api.nvim_create_user_command("AgdaRestart", function()
    M.AgdaRestart()
  end, {})

  vim.api.nvim_create_user_command("AgdaVersion", function(opts)
    M.AgdaVersion({ quiet = cmd_bool_bang(opts) })
  end, { bang = true })

  vim.api.nvim_create_user_command("AgdaLoad", function(opts)
    M.AgdaLoad({ quiet = cmd_bool_bang(opts) })
  end, { bang = true })

  vim.api.nvim_create_user_command("AgdaLoadHighlightInfo", function(opts)
    M.AgdaLoadHighlightInfo({ quiet = cmd_bool_bang(opts) })
  end, { bang = true })

  vim.api.nvim_create_user_command("AgdaGotoAnnotation", function()
    M.AgdaGotoAnnotation()
  end, {})

  vim.api.nvim_create_user_command("AgdaGive", function()
    M.AgdaGive()
  end, {})

  vim.api.nvim_create_user_command("AgdaMakeCase", function()
    M.AgdaMakeCase()
  end, {})

  vim.api.nvim_create_user_command("AgdaRefine", function(opts)
    M.AgdaRefine(opts.args)
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("AgdaAuto", function()
    M.AgdaAuto()
  end, {})

  vim.api.nvim_create_user_command("AgdaContext", function()
    M.AgdaContext()
  end, {})

  vim.api.nvim_create_user_command("AgdaInfer", function()
    M.AgdaInfer()
  end, {})

  vim.api.nvim_create_user_command("AgdaNormalize", function(opts)
    M.AgdaNormalize(opts.args)
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("AgdaWhyInScope", function(opts)
    M.AgdaWhyInScope(opts.args or "")
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AgdaShowModule", function(opts)
    M.AgdaShowModule(opts.args or "")
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AgdaHelperFunction", function()
    M.AgdaHelperFunction()
  end, {})

  vim.api.nvim_create_user_command("AgdaSetRewriteMode", function(opts)
    M.SetRewriteMode(opts.args)
    notify("rewriteMode = " .. state.rewriteMode)
  end, { nargs = 1 })

  -- Start Agda lazily on first command; if you prefer eager:
  -- start_agda()
end

return M
