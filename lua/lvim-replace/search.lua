-- lvim-replace.search: the ripgrep backend — argv construction, off-main-thread streaming and parsing.
-- ripgrep is the SINGLE engine for BOTH search and replace (grug-far's "one tool" philosophy), so a
-- regex written once behaves identically in the results and in the applied change:
--
--   PASS 1  `rg --json …`                              → authoritative matches: file, line, the line
--                                                         text, and every submatch's BYTE span. Drives
--                                                         the results list, the match highlight, marking
--                                                         and navigation.
--   PASS 2  `rg -o --column --line-number --replace=… …` (only when a Replace value is set) → ripgrep's
--                                                         OWN replacement text per match (capture groups
--                                                         `$1` expanded correctly). Zipped onto pass-1's
--                                                         spans by (file, line, col) so each span gains an
--                                                         `after`. `rg --json` ignores `--replace`, which
--                                                         is exactly why the replacement needs its own pass.
--
-- Both passes run through `vim.system` (libuv, off the main thread); stdout is parsed incrementally in
-- the read callback (pure string + `vim.json.decode` work only — no editor calls) and re-renders are
-- THROTTLED onto the main loop, so a broad search never blocks typing. A result cap kills ripgrep at the
-- ceiling so a pathological query can't buffer unbounded output.
--
---@module "lvim-replace.search"

local config = require("lvim-replace.config")

local M = {}

--- True when ripgrep is on PATH.
---@return boolean
function M.has_rg()
    return vim.fn.executable("rg") == 1
end

--- The case flag for the current mode ("smart" | "ignore" | "sensitive").
---@param case string
---@return string
local function case_flag(case)
    if case == "ignore" then
        return "--ignore-case"
    elseif case == "sensitive" then
        return "--case-sensitive"
    end
    return "--smart-case"
end

--- Split a free-form Flags string into argv tokens (whitespace-separated; quoted groups honoured).
---@param s string
---@return string[]
local function split_flags(s)
    local out = {}
    if not s or s == "" then
        return out
    end
    -- Honour simple single/double quoting so a flag value with a space (a glob) survives as ONE
    -- token — e.g. `-g 'my dir/*'` → { "-g", "my dir/*" }. A plain %S+ split (what this used to do
    -- despite the comment) broke such a value into two bogus argv tokens.
    local i, n = 1, #s
    while i <= n do
        if s:sub(i, i):match("%s") then
            i = i + 1
        else
            local tok = {}
            while i <= n do
                local ch = s:sub(i, i)
                if ch:match("%s") then
                    break
                elseif ch == "'" or ch == '"' then
                    i = i + 1
                    while i <= n and s:sub(i, i) ~= ch do
                        tok[#tok + 1] = s:sub(i, i)
                        i = i + 1
                    end
                    i = i + 1 -- past the closing quote (or past end for an unterminated quote)
                else
                    tok[#tok + 1] = ch
                    i = i + 1
                end
            end
            out[#out + 1] = table.concat(tok)
        end
    end
    return out
end

--- Build the ripgrep argv shared by both passes: the flag state (case / word / regex / multiline /
--- hidden / ignore), the Files glob filter, the config excludes, the free-form extra Flags, then the
--- Search term and the positional paths. `mode` selects the pass-specific head:
---   "json"    → `--json` (matches + spans + line text)
---   "replace" → `-o --column --line-number --no-heading --color=never -H --replace=<replace>`
--- `st` is the live panel state (fields + flag toggles + scope paths).
---@param st table
---@param mode "json"|"replace"
---@return string[]
function M.build_argv(st, mode)
    local f = st.flags
    local argv = { "rg" }
    if mode == "json" then
        argv[#argv + 1] = "--json"
    else
        -- Only-matching + column + forced filename → one `path:line:col:<replacement>` row per match,
        -- uniform whether one file or a whole tree is searched (-H forces the path even for a single file).
        vim.list_extend(argv, {
            "--only-matching",
            "--column",
            "--line-number",
            "--no-heading",
            "--color=never",
            "-H",
            "--replace=" .. (st.replace or ""),
        })
    end
    -- Per-line length cap: a broad search over a tree hits minified bundles whose single line is megabytes;
    -- `--vimgrep`/`--json` print the whole matched line, so cap it (still previewed, just truncated).
    local maxcol = tonumber(config.max_columns) or 512
    if maxcol > 0 and mode == "json" then
        argv[#argv + 1] = "--max-columns"
        argv[#argv + 1] = tostring(maxcol)
        argv[#argv + 1] = "--max-columns-preview"
    end
    argv[#argv + 1] = case_flag(f.case)
    if f.whole_word then
        argv[#argv + 1] = "--word-regexp"
    end
    if not f.regex then
        argv[#argv + 1] = "--fixed-strings"
    end
    if f.multiline then
        argv[#argv + 1] = "--multiline"
        argv[#argv + 1] = "--multiline-dotall"
    end
    if f.hidden then
        argv[#argv + 1] = "--hidden"
    end
    if f.no_ignore then
        argv[#argv + 1] = "--no-ignore"
    end
    for _, g in ipairs(config.exclude or {}) do
        argv[#argv + 1] = "-g"
        argv[#argv + 1] = "!" .. g
    end
    -- Files filter: whitespace-separated globs → one `-g <glob>` each (grug-far's Files input).
    for _, g in ipairs(split_flags(st.paths)) do
        argv[#argv + 1] = "-g"
        argv[#argv + 1] = g
    end
    -- Free-form extra ripgrep flags (the transparency escape hatch).
    vim.list_extend(argv, split_flags(st.flags_extra))
    argv[#argv + 1] = "--"
    argv[#argv + 1] = st.search
    -- Positional scope paths (a current-file / directory scope); default the cwd tree.
    if st.scope_paths and #st.scope_paths > 0 then
        vim.list_extend(argv, st.scope_paths)
    else
        argv[#argv + 1] = "."
    end
    return argv
end

--- Parse one `rg --json` "match" object into a result line, appending it to `acc` (grouped by file,
--- preserving discovery order). Returns whether the result cap was reached.
---@param obj table  a decoded rg --json record
---@param acc { files: table[], index: table<string, integer>, count: integer }
---@param cap integer
---@return boolean capped
local function ingest_match(obj, acc, cap)
    if obj.type ~= "match" then
        return false
    end
    local data = obj.data
    local path = data.path and data.path.text
    if not path then
        return false
    end
    -- Strip the FULL line terminator, CRLF included: a bare `\n$` gsub left the `\r` of a CRLF file
    -- on the text, which later became a trailing SPACE (ui flatten) so apply's `cur ~= text` equality
    -- never held → every match on a CRLF file was skipped as "changed since search".
    local text = (data.lines and data.lines.text or ""):gsub("\r?\n$", ""):gsub("\r$", "")
    local spans = {}
    for _, sm in ipairs(data.submatches or {}) do
        spans[#spans + 1] = { s = sm.start, e = sm["end"] }
    end
    local gi = acc.index[path]
    if not gi then
        acc.files[#acc.files + 1] = { path = path, matches = {} }
        gi = #acc.files
        acc.index[path] = gi
    end
    local grp = acc.files[gi]
    grp.matches[#grp.matches + 1] = { lnum = data.line_number, text = text, spans = spans }
    acc.count = acc.count + 1
    return acc.count >= cap
end

--- Zip a pass-2 replacement map (`"<path>\0<lnum>\0<col>" → replaced text`) onto the accumulated spans:
--- each span's `after` is the replacement whose column equals the span start + 1 (rg columns are 1-based).
---@param acc { files: table[] }
---@param repl table<string, string>
local function attach_replacements(acc, repl)
    for _, grp in ipairs(acc.files) do
        for _, m in ipairs(grp.matches) do
            for _, sp in ipairs(m.spans) do
                local key = grp.path .. "\0" .. tostring(m.lnum) .. "\0" .. tostring(sp.s + 1)
                sp.after = repl[key]
            end
        end
    end
end

--- Parse a pass-2 `path:lnum:col:text` line into the replacement map, keyed the same way as
--- `attach_replacements` reads it. `paths` is the ordered file set from pass 1 (longest-prefix match
--- disambiguates a filename that itself contains a colon; the replaced text keeps its own colons).
---@param line string
---@param paths string[]
---@param repl table<string, string>
local function ingest_replace_line(line, paths, repl)
    -- Find the source path by prefix (rg prints exactly the path string it was given, identical to pass 1).
    local best
    for _, p in ipairs(paths) do
        if line:sub(1, #p + 1) == p .. ":" and (not best or #p > #best) then
            best = p
        end
    end
    if not best then
        return
    end
    local rest = line:sub(#best + 2) -- after "<path>:"
    local lnum, col, text = rest:match("^(%d+):(%d+):(.*)$")
    if not lnum then
        return
    end
    repl[best .. "\0" .. lnum .. "\0" .. col] = text
end

--- Run a full search for the current panel `st`: pass 1 (matches, streamed + throttled) then, when a
--- Replace value is present, pass 2 (replacement text). `on_update(acc)` is called on the main loop as
--- results accumulate (throttled); `on_done(acc, err)` fires once at the end (`err` = ripgrep's stderr
--- on a bad regex / flag, so the UI can surface it). Returns a cancel function that kills both passes.
---@param st table
---@param on_update fun(acc: table)
---@param on_done fun(acc: table, err: string?)
---@return fun() cancel
function M.run(st, on_update, on_done)
    local cap = tonumber(config.max_results) or 2000
    local acc = { files = {}, index = {}, count = 0 }
    local cancelled = false
    ---@type vim.SystemObj?
    local sys1, sys2
    local dirty, throttle = false, nil

    local function stop_throttle()
        if throttle then
            throttle:stop()
            if not throttle:is_closing() then
                throttle:close()
            end
            throttle = nil
        end
    end

    -- Throttle progressive re-renders to ~60ms so a fast producer doesn't schedule a render per chunk.
    throttle = vim.uv.new_timer()
    throttle:start(60, 60, function()
        if cancelled or not dirty then
            return
        end
        dirty = false
        vim.schedule(function()
            if not cancelled then
                on_update(acc)
            end
        end)
    end)

    --- Line-splitting consumer shared by both passes: buffers a partial trailing line across chunks.
    ---@param handler fun(line: string)
    ---@return fun(err: string?, data: string?)
    local function line_reader(handler)
        local rest = ""
        return function(err, data)
            if err or not data or cancelled then
                return
            end
            rest = rest .. data
            local start = 1
            while true do
                local nl = rest:find("\n", start, true)
                if not nl then
                    break
                end
                handler(rest:sub(start, nl - 1))
                start = nl + 1
            end
            rest = rest:sub(start)
        end
    end

    local stderr_buf = {}

    --- Pass 2: replacement text. Runs after pass 1 so the file set (for prefix disambiguation) exists. Only
    --- when a Replace VALUE is set — an empty Replace needs no replacement text (the UI just strikes the match
    --- as a deletion indicator), so the second ripgrep pass is skipped.
    local function run_replace()
        if cancelled or (st.replace or "") == "" or acc.count == 0 then
            stop_throttle()
            return vim.schedule(function()
                if not cancelled then
                    on_done(acc, #stderr_buf > 0 and table.concat(stderr_buf) or nil)
                end
            end)
        end
        local paths = {}
        for _, grp in ipairs(acc.files) do
            paths[#paths + 1] = grp.path
        end
        local repl = {}
        local reader = line_reader(function(line)
            ingest_replace_line(line, paths, repl)
        end)
        local ok, obj = pcall(vim.system, M.build_argv(st, "replace"), { text = true, stdout = reader }, function()
            attach_replacements(acc, repl)
            stop_throttle()
            vim.schedule(function()
                if not cancelled then
                    on_update(acc)
                    -- surface pass-1 stderr on the replace path too (permission-denied subtrees, a bad
                    -- -g glob that still matched) — it was only reported on the no-replace exit before
                    on_done(acc, #stderr_buf > 0 and table.concat(stderr_buf) or nil)
                end
            end)
        end)
        sys2 = ok and obj or nil
        if not ok then
            stop_throttle()
            vim.schedule(function()
                if not cancelled then
                    on_done(acc, nil)
                end
            end)
        end
    end

    -- Pass 1: matches (JSON), streamed.
    local reader = line_reader(function(line)
        if line == "" or acc.count >= cap then
            return -- once capped, drop the rest of this (and any already-piped) chunk: the soft cap
            -- otherwise lets acc.count overshoot max_results by the remainder of the buffered stdout
        end
        local ok, obj = pcall(vim.json.decode, line)
        if ok and type(obj) == "table" then
            if ingest_match(obj, acc, cap) then
                if sys1 then
                    pcall(function()
                        sys1:kill("sigterm")
                    end)
                end
            end
            dirty = true
        end
    end)
    local ok1, obj1 = pcall(vim.system, M.build_argv(st, "json"), {
        text = true,
        stdout = reader,
        stderr = function(_, data)
            if data then
                stderr_buf[#stderr_buf + 1] = data
            end
        end,
    }, function()
        run_replace()
    end)
    sys1 = ok1 and obj1 or nil
    if not ok1 then
        stop_throttle()
        vim.schedule(function()
            if not cancelled then
                on_done(acc, "failed to launch ripgrep")
            end
        end)
    end

    return function()
        cancelled = true
        stop_throttle()
        pcall(function()
            if sys1 then
                sys1:kill("sigterm")
            end
        end)
        pcall(function()
            if sys2 then
                sys2:kill("sigterm")
            end
        end)
    end
end

return M
