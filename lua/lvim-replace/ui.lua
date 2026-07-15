-- lvim-replace.ui: the find & replace PANEL — a docked SPLIT (never a centred float), built as a stack of
-- three navigable SECTORS on lvim-ui.surface's vertical multi-panel sector model (`direction = "vertical"`,
-- `center_panel_sectors = true` — the surface names lvim-replace as exactly this shape):
--
--   sector 1  INPUTS   — Search / Replace / Files / Flags, one row each (an EDITABLE buffer — typed inline)
--   sector 2  TOGGLES  — Case / Whole word / Regex / Hidden as a single CENTERED row of buttons
--   sector 3  RESULTS  — a Mark all / Unmark all bar + the match rows, grouped by file (SELECTIVE APPLY)
--   footer             — Replace / Undo / Help / Close, reachable from EVERY sector
--
-- `<C-j>` / `<C-k>` step between the sectors and the footer. The INPUTS sector is a real editable buffer: you
-- type in the four field lines (the cursor shows only while inserting — normal / visual mode hides it, like
-- the other sectors), and the search re-runs (debounced) on every edit. The TOGGLES sector hides its cursor;
-- h / l pick a button and `<CR>` / `<Space>` flips it. The RESULTS sector hides its cursor too: on the Mark
-- bar (row 1) h / l pick a button and `<CR>` runs it; on a match `<CR>` jumps to it and the mark key marks it.
-- The active-row / active-button tint shows ONLY in the focused sector (leaving a sector clears it). Each
-- sector's border + separator is configurable (`config.sectors`); the footer keys (`r` replace · `u` undo ·
-- `g?` help · `q` close) and `m` / `n` (mark all / unmark all) fire frame-wide, from any sector. Only `q`
-- closes the panel (`<Esc>` just leaves insert in the inputs).
--
-- SELECTIVE APPLY (the headline feature): the result under the cursor is marked/unmarked (or a file header to
-- mark all its matches), the Mark bar shows a live "marked / total" counter, and APPLY writes ONLY the marked
-- matches (or all when none are marked, after a confirm that states the count). Marks are keyed by a stable
-- result id and re-applied on every render, so the marker column survives re-render.
--
-- The preview is always live (from the first Search character). A Replace VALUE renders each match as a
-- two-row DIFF: the ORIGINAL on a faint red wash (matched span red + struck through) and the REPLACEMENT
-- below it on a faint green wash with a `+` gutter (ripgrep's own replacement, capture groups expanded, in
-- green). An EMPTY Replace renders a SINGLE row with the match struck through (a "will be deleted"
-- indicator). The result line's code reads in yellow; the match / replacement spans paint over it.
--
---@module "lvim-replace.ui"

local api = vim.api
local config = require("lvim-replace.config")
local search = require("lvim-replace.search")
local apply = require("lvim-replace.apply")
local store = require("lvim-replace.store")
local iconlib = require("lvim-utils.icons")
local surface = require("lvim-ui.surface")
local cursor = require("lvim-utils.cursor")

-- The four input fields, top-to-bottom. Each has its OWN accent (the тинт canon): `row_hl` tints the whole
-- row toward the bg with the accent as the fg (so the value reads in the field's colour), `badge_hl` is a
-- stronger tint for the label badge, and `sel_hl` is the ACTIVE-row (deeper) variant of the same accent.
local FIELDS = {
    {
        key = "search",
        label = "Search",
        row_hl = "LvimReplaceFieldSearch",
        badge_hl = "LvimReplaceFieldSearchBadge",
        sel_hl = "LvimReplaceFieldSearchSel",
    },
    {
        key = "replace",
        label = "Replace",
        row_hl = "LvimReplaceFieldReplace",
        badge_hl = "LvimReplaceFieldReplaceBadge",
        sel_hl = "LvimReplaceFieldReplaceSel",
    },
    {
        key = "paths",
        label = "Files",
        row_hl = "LvimReplaceFieldFiles",
        badge_hl = "LvimReplaceFieldFilesBadge",
        sel_hl = "LvimReplaceFieldFilesSel",
    },
    {
        key = "flags_extra",
        label = "Flags",
        row_hl = "LvimReplaceFieldFlags",
        badge_hl = "LvimReplaceFieldFlagsBadge",
        sel_hl = "LvimReplaceFieldFlagsSel",
    },
}

local BADGE_W = 7 -- the label badge width (the inline field badges align on their value column)
local FIELD_COUNT = #FIELDS

-- The inputs sector is a REAL editable buffer (the four fields are typed inline); its field badges + row
-- tints are our OWN extmarks in this namespace (the chassis never paints an `update`/editable panel).
local NS = vim.api.nvim_create_namespace("lvim-replace")

local M = {}

--- A config key value (single key / list / "") → a list of keys.
---@param v string|string[]|nil
---@return string[]
local function keylist(v)
    if type(v) == "table" then
        return v
    end
    return (type(v) == "string" and v ~= "") and { v } or {}
end

---@type table?  the live panel's control handle
local current = nil

--- Open (or re-focus) the find & replace panel.
---@param opts? { prefills?: table, scope_paths?: string[], flags?: table, title?: string }
function M.open(opts)
    opts = opts or {}
    if current then
        current.apply_prefills(opts)
        current.focus()
        return
    end

    local prefills = opts.prefills or {}
    local marker = config.marker or "➤"
    local base_title = opts.title or "Find & Replace"

    -- ── the per-open instance (all helpers below close over it) ──────────────────
    local S = {
        search = prefills.search or "",
        replace = prefills.replace or "",
        paths = prefills.paths or "",
        flags_extra = prefills.flags_extra or "",
        flags = vim.tbl_extend("force", vim.deepcopy(config.flags), opts.flags or {}),
        scope_paths = opts.scope_paths or {},
        ---@type { files: table[], index: table<string, integer>, count: integer }
        results = { files = {}, index = {}, count = 0 },
        rows = {},
        marked = {},
        searching = false,
        opener = api.nvim_get_current_win(),
        closed = false,
        ---@type table?  the surface control handle
        st = nil,
        ---@type table?  the inputs layer panel
        pan_inputs = nil,
        ---@type table?  the toggles layer panel
        pan_toggles = nil,
        ---@type table?  the results layer panel
        pan_results = nil,
        ---@type fun()?
        search_cancel = nil,
        ---@type uv.uv_timer_t?
        debounce = nil,
    }

    --- Resolve a configured highlight group name (allowing user `config.hl` overrides).
    ---@param name string
    ---@return string
    local function hl(name)
        return (config.hl or {})[name] or name
    end

    --- The cursor line (1-based) of a panel's window, defaulting to 1 when it is not the current layout.
    ---@param pan table?
    ---@return integer
    local function pan_sel(pan)
        if pan and pan.win and api.nvim_win_is_valid(pan.win) then
            return api.nvim_win_get_cursor(pan.win)[1]
        end
        return 1
    end

    --- Whether a layer's window is the CURRENTLY focused one — the active-row / active-button tint shows ONLY
    --- in the focused sector, so leaving a sector drops its highlight and a fresh open shows none anywhere.
    ---@param pan table?
    ---@return boolean
    local function is_focused(pan)
        return pan ~= nil
            and pan.win ~= nil
            and api.nvim_win_is_valid(pan.win)
            and api.nvim_get_current_win() == pan.win
    end

    -- ── result rows + marking ────────────────────────────────────────────────────

    local function rebuild_rows()
        local rows = {}
        for gi, grp in ipairs(S.results.files) do
            rows[#rows + 1] = { kind = "file", path = grp.path, gi = gi, count = #grp.matches, id = "F\0" .. grp.path }
            for mi, m in ipairs(grp.matches) do
                rows[#rows + 1] = {
                    kind = "match",
                    path = grp.path,
                    gi = gi,
                    mi = mi,
                    lnum = m.lnum,
                    text = (m.text or ""):gsub("[\r\n]", " "),
                    spans = m.spans,
                    id = grp.path .. "\0" .. tostring(m.lnum),
                }
            end
        end
        S.rows = rows
    end

    ---@param row table
    ---@return string[]
    local function file_match_ids(row)
        local ids = {}
        local grp = S.results.files[row.gi]
        for _, m in ipairs(grp and grp.matches or {}) do
            ids[#ids + 1] = grp.path .. "\0" .. tostring(m.lnum)
        end
        return ids
    end

    ---@param row table
    ---@return boolean
    local function is_marked(row)
        if row.kind == "match" then
            return S.marked[row.id] == true
        end
        local ids = file_match_ids(row)
        if #ids == 0 then
            return false
        end
        for _, id in ipairs(ids) do
            if not S.marked[id] then
                return false
            end
        end
        return true
    end

    ---@return integer
    local function marked_count()
        local n = 0
        for _, row in ipairs(S.rows) do
            if row.kind == "match" and S.marked[row.id] then
                n = n + 1
            end
        end
        return n
    end

    -- ── after-line (replacement preview) ─────────────────────────────────────────

    ---@param spans table[]
    ---@return boolean
    local function all_have_after(spans)
        for _, sp in ipairs(spans) do
            if sp.after == nil then
                return false
            end
        end
        return #spans > 0
    end

    ---@param text string
    ---@param spans { s: integer, e: integer, after: string? }[]
    ---@return string line, { c0: integer, c1: integer }[] adds
    local function build_after(text, spans)
        local ordered = {}
        for _, sp in ipairs(spans) do
            ordered[#ordered + 1] = sp
        end
        table.sort(ordered, function(a, b)
            return a.s < b.s
        end)
        local out, adds, last, pos = {}, {}, 0, 0
        for _, sp in ipairs(ordered) do
            local pre = text:sub(last + 1, sp.s)
            out[#out + 1] = pre
            pos = pos + #pre
            local rep = sp.after or ""
            adds[#adds + 1] = { c0 = pos, c1 = pos + #rep }
            out[#out + 1] = rep
            pos = pos + #rep
            last = sp.e
        end
        out[#out + 1] = text:sub(last + 1)
        return table.concat(out), adds
    end

    -- ── the live title counter ────────────────────────────────────────────────────

    --- The live "marked / total" counter text (shown right-aligned on the toggles layer's Mark-all row).
    ---@return string
    local function counter_text()
        local total = S.results.count or 0
        return total > 0 and ("%d / %d marked"):format(marked_count(), total) or ""
    end

    -- ── layer 1: INPUTS (an editable buffer — the four fields are typed inline) ─────

    --- Paint the four field rows' chrome as extmarks (our own namespace — the chassis never writes an editable
    --- panel): each row a full-width accent tint whose fg is the accent (so the typed value reads in the field's
    --- colour), plus the inline label BADGE (a stronger tint) and a 1-space gap before the value. `right_gravity
    --- = false` anchors both at column 0 so typing at the head keeps the styling in place.
    ---@param buf integer
    local function apply_field_styling(buf)
        api.nvim_buf_clear_namespace(buf, NS, 0, -1)
        for i, f in ipairs(FIELDS) do
            local row = i - 1
            pcall(api.nvim_buf_set_extmark, buf, NS, row, 0, {
                end_row = row + 1,
                hl_group = hl(f.row_hl),
                hl_eol = true,
                right_gravity = false,
                priority = 90,
            })
            pcall(api.nvim_buf_set_extmark, buf, NS, row, 0, {
                virt_text = {
                    { (" %-" .. BADGE_W .. "s "):format(f.label), hl(f.badge_hl) },
                    { " ", hl(f.row_hl) },
                },
                virt_text_pos = "inline",
                right_gravity = false,
            })
        end
    end

    --- Rewrite the four field lines from `S` (on open and when a snapshot / prefill is loaded) and re-style.
    local function inputs_rewrite()
        local pan = S.pan_inputs
        if not (pan and pan.buf and api.nvim_buf_is_valid(pan.buf)) then
            return
        end
        vim.bo[pan.buf].modifiable = true
        api.nvim_buf_set_lines(pan.buf, 0, -1, false, { S.search, S.replace, S.paths, S.flags_extra })
        apply_field_styling(pan.buf)
    end

    --- Read the four field lines back into `S`; if any changed, debounce a search. The field region is a FIXED
    --- four lines — a structure-changing edit (join / delete / multiline paste) is self-healed by rewriting the
    --- last-good values from `S`, so a merge can never persist or feed the search.
    local function sync_fields()
        local pan = S.pan_inputs
        if not (pan and pan.buf and api.nvim_buf_is_valid(pan.buf)) then
            return
        end
        if api.nvim_buf_line_count(pan.buf) ~= FIELD_COUNT then
            inputs_rewrite()
            return
        end
        local l = api.nvim_buf_get_lines(pan.buf, 0, FIELD_COUNT, false)
        local nf = { search = l[1] or "", replace = l[2] or "", paths = l[3] or "", flags_extra = l[4] or "" }
        local changed = nf.search ~= S.search
            or nf.replace ~= S.replace
            or nf.paths ~= S.paths
            or nf.flags_extra ~= S.flags_extra
        S.search, S.replace, S.paths, S.flags_extra = nf.search, nf.replace, nf.paths, nf.flags_extra
        if changed then
            S.schedule_search()
        end
    end

    -- ── layer 2: TOGGLES (one row of four buttons) ────────────────────────────────

    --- The four search-flag toggles, in left-to-right order — the toggles sector is a SINGLE row of buttons.
    ---@return table[]
    local function toggle_defs()
        local f = S.flags
        return {
            { id = "case", label = "Case", value = f.case, kind = "value", action = S.toggle_case },
            { id = "word", label = "Whole word", on = f.whole_word, kind = "flag", action = S.toggle_word },
            { id = "regex", label = "Regex", on = f.regex, kind = "flag", action = S.toggle_regex },
            { id = "hidden", label = "Hidden", on = f.hidden, kind = "flag", action = S.toggle_hidden },
        }
    end

    local TOGGLE_GAP = 4 -- spaces between buttons (≥2 so the 1-space hover pads never touch a neighbour)

    --- Build the single toggles row: the four flag buttons CENTERED in the sector, the SELECTED one
    --- (`S.toggle_sel`, moved with h/l) painted with the active bar that includes 1 space of padding on each
    --- side; each button's label + coloured state.
    ---@param width integer
    ---@return string[] lines, table[] hls
    local function toggles_lines(width)
        local defs = toggle_defs()
        local sel = math.min(math.max(S.toggle_sel or 1, 1), #defs)
        -- Measure the buttons first (to centre the whole run), then lay them out from the leading pad.
        local segtxt, total = {}, 0
        for i, d in ipairs(defs) do
            local state = d.kind == "value" and tostring(d.value) or (d.on and "on" or "off")
            segtxt[i] = d.label .. ": " .. state
            total = total + #segtxt[i] + (i > 1 and TOGGLE_GAP or 0)
        end
        local lead = math.max(1, math.floor((width - total) / 2))
        local line, x, segs = string.rep(" ", lead), lead, {}
        for i, d in ipairs(defs) do
            if i > 1 then
                line = line .. string.rep(" ", TOGGLE_GAP)
                x = x + TOGGLE_GAP
            end
            segs[i] = { c0 = x, lend = x + #d.label, sstart = x + #d.label + 2, c1 = x + #segtxt[i], d = d }
            line = line .. segtxt[i]
            x = x + #segtxt[i]
        end
        -- Pad the row to the full width so the LAST button's trailing hover pad (`c1 + 1`) has a real cell.
        line = line .. string.rep(" ", math.max(1, width - x))
        local focused = is_focused(S.pan_toggles)
        local hls = { { 0, 0, -1, "LvimReplaceToggleRow", 90 } }
        for i, s in ipairs(segs) do
            if focused and i == sel then
                -- The hover bar wraps the button with 1 space of padding on each side.
                hls[#hls + 1] = { 0, s.c0 - 1, s.c1 + 1, "LvimReplaceActiveRow", 200 }
            end
            hls[#hls + 1] = { 0, s.c0, s.lend, "LvimReplaceToggleLabel", 210 }
            local vhl = s.d.kind == "value" and "LvimReplaceToggleValue"
                or (s.d.on and "LvimReplaceToggleOn" or "LvimReplaceToggleOff")
            hls[#hls + 1] = { 0, s.sstart, s.c1, vhl, 210 }
        end
        return { line }, hls
    end

    --- Move the toggle-button selection by `delta` (h/l), then repaint.
    ---@param delta integer
    local function toggle_move(delta)
        local n = #toggle_defs()
        S.toggle_sel = math.min(math.max((S.toggle_sel or 1) + delta, 1), n)
        if S.pan_toggles and S.pan_toggles.refresh then
            S.pan_toggles.refresh()
        end
    end

    --- Flip the selected toggle button.
    local function toggles_activate()
        local d = toggle_defs()[math.min(math.max(S.toggle_sel or 1, 1), #toggle_defs())]
        if d and d.action then
            d.action()
        end
    end

    -- ── layer 3: RESULTS (a Mark-all / Unmark-all bar + the match list) ───────────

    -- The Mark bar buttons: a bracketed hotkey somewhere in the label (`[m]ark all` / `U[n]mark all` — `n`
    -- so it never collides with `u` = undo). The key is active ONLY from the results sector; the bar is a
    -- NON-INTERACTIVE header row (the cursor never lands on it). `pre`/`hot`/`post` = label before the bracket,
    -- the bracketed key, the label after.
    local MARK_BTNS = {
        { pre = "", hot = "m", post = "ark all" }, -- [m]ark all
        { pre = "u", hot = "n", post = "mark all" }, -- u[n]mark all
    }

    --- The Mark-all / Unmark-all BAR — the first (non-navigable) row of the results sector: `[m]ark all
    --- U[n]mark all` (the bracketed key in blue, the label in yellow) + the right-aligned green counter badge.
    ---@param width integer
    ---@return string line, table[] hls
    local function mark_bar(width)
        local line, x = "  ", 2
        local hls = { { 0, 0, -1, "LvimReplaceActionRow", 90 } }
        for i, b in ipairs(MARK_BTNS) do
            if i > 1 then
                line = line .. "    "
                x = x + 4
            end
            local seg = b.pre .. "[" .. b.hot .. "]" .. b.post
            local kc0 = x + #b.pre -- the "[x]" hotkey box start
            if #b.pre > 0 then
                hls[#hls + 1] = { 0, x, kc0, "LvimReplaceAction", 210 } -- label before the bracket (yellow)
            end
            hls[#hls + 1] = { 0, kc0, kc0 + 3, "LvimReplaceActionKey", 210 } -- the "[x]" hotkey box (blue)
            hls[#hls + 1] = { 0, kc0 + 3, x + #seg, "LvimReplaceAction", 210 } -- label after the bracket (yellow)
            line = line .. seg
            x = x + #seg
        end
        -- The counter is a green BADGE flush to the RIGHT edge (the pickers' count box): 1 space of padding on
        -- the left, and the trailing edge sits on the last column (no right gap).
        local count = counter_text()
        local badge = count ~= "" and (" " .. count .. " ") or ""
        if badge ~= "" then
            local pad = math.max(2, width - x - #badge)
            line = line .. string.rep(" ", pad) .. badge
            hls[#hls + 1] = { 0, #line - #badge, #line, "LvimReplaceCount", 210 }
        end
        return line, hls
    end

    --- Build the result lines + highlights. Row 1 is the Mark bar; the match rows follow. With a Replace value
    --- each match renders as a two-row DIFF — the ORIGINAL on a faint red wash (matched span red + struck) and
    --- the REPLACEMENT below it on a faint green wash (the inserted text green). `S.line_rows` maps every buffer
    --- line back to its `S.rows` index (false for the bar / empty message), so navigation survives the
    --- variable line-per-match count. The ACTIVE row (all lines of the match under the hidden cursor) gets the
    --- accent bar; a marked row keeps the marker glyph in its front column.
    ---@param width integer
    ---@return string[] lines, table[] hls
    local function results_lines(width)
        rebuild_rows()
        local focused = is_focused(S.pan_results)
        local sel = pan_sel(S.pan_results)
        local bar_line, bar_hls = mark_bar(width)
        local lines, hls = { bar_line }, bar_hls
        ---@type (integer|false)[]  buffer line (1-based) → S.rows index; false = non-navigable
        local line_rows = { false }
        S.line_rows = line_rows
        if #S.rows == 0 then
            local msg, group
            if S.err and S.err ~= "" then
                msg, group = "  " .. (S.err:gsub("[\r\n]+", " ")), "LvimReplaceError"
            elseif S.searching then
                msg, group = "  Searching…", "LvimReplaceEmpty"
            elseif #(S.search or "") < config.min_chars then
                msg, group = ("  Type at least %d character(s) to search"):format(config.min_chars), "LvimReplaceEmpty"
            else
                msg, group = "  No matches", "LvimReplaceEmpty"
            end
            lines[2] = msg
            line_rows[2] = false
            hls[#hls + 1] = { 1, 0, -1, group, 100 }
            return lines, hls
        end
        --- Append one buffer line, mapping it to `rowidx` (nil = non-navigable). Returns its 0-based buffer row.
        ---@param text string
        ---@param rowidx integer|nil
        ---@return integer
        local function push(text, rowidx)
            lines[#lines + 1] = text
            line_rows[#lines] = rowidx or false
            return #lines - 1
        end
        for i, row in ipairs(S.rows) do
            local marked = is_marked(row)
            local mk = marked and marker or " "
            if row.kind == "file" then
                local ic = iconlib.get(row.path, {})
                local glyph = ic.glyph or ""
                local rel = vim.fn.fnamemodify(row.path, ":.")
                local head = mk .. " " .. (glyph ~= "" and (glyph .. " ") or "") .. rel
                local cnt = ("  (%d)"):format(row.count)
                local br = push(head .. cnt, i)
                hls[#hls + 1] = { br, 0, -1, "LvimReplaceFileRow", 100 }
                local pstart = #mk + 1 + (glyph ~= "" and (#glyph + 1) or 0)
                if glyph ~= "" then
                    local ihl = (ic.hl and ic.hl ~= "") and ic.hl or "LvimReplaceIcon"
                    hls[#hls + 1] = { br, #mk + 1, #mk + 1 + #glyph, ihl, 160 }
                end
                hls[#hls + 1] = { br, pstart, pstart + #rel, "LvimReplaceFilePath", 150 }
                hls[#hls + 1] = { br, #head, #(head .. cnt), "LvimReplaceFileCount", 150 }
                if marked then
                    hls[#hls + 1] = { br, 0, #mk, "LvimReplaceMarker", 220 }
                end
            else
                local col1 = (row.spans[1] and row.spans[1].s or 0) + 1
                local loc = ("%d:%d"):format(row.lnum, col1)
                local prefix = mk .. " " .. loc .. "  "
                -- The preview is always live (no gate): a Replace VALUE renders the full two-row DIFF, an EMPTY
                -- Replace renders a SINGLE row with the match struck through (a "will be deleted" indicator).
                local diff = (S.replace ~= "") and all_have_after(row.spans)
                -- ── the ORIGINAL (before) row ──────────────────────────────────────
                local before = prefix .. row.text
                local br = push(before, i)
                hls[#hls + 1] = {
                    br,
                    0,
                    -1,
                    diff and "LvimReplaceDiffDel" or (i % 2 == 1 and "LvimReplaceRowOdd" or "LvimReplaceRowEven"),
                    100,
                }
                local locstart = #mk + 1
                local lnum_bytes = #tostring(row.lnum)
                hls[#hls + 1] = { br, locstart, locstart + lnum_bytes, "LvimReplaceLineNr", 150 }
                hls[#hls + 1] = { br, locstart + lnum_bytes + 1, locstart + #loc, "LvimReplaceColNr", 150 }
                hls[#hls + 1] = { br, #prefix, #before, "LvimReplaceCode", 150 } -- the code text in yellow
                -- The match is always struck (red): a Replace value replaces it, an empty Replace deletes it.
                for _, sp in ipairs(row.spans) do
                    hls[#hls + 1] = { br, #prefix + sp.s, #prefix + sp.e, "LvimReplaceMatchDel", 160 }
                end
                if marked then
                    hls[#hls + 1] = { br, 0, #mk, "LvimReplaceMarker", 220 }
                end
                -- ── the REPLACEMENT (after) row — a diff only ──────────────────────
                if diff then
                    local body, adds = build_after(row.text, row.spans)
                    -- Align the replacement body under the ORIGINAL body by DISPLAY width, not byte length —
                    -- the marker glyph (`➤`) is 3 bytes but ONE cell, so a byte-based gutter shifted the `+`
                    -- (and the whole replacement) inward on a marked row. `aprefix` is pure ASCII, so its byte
                    -- length equals its cell width = the original prefix's display width.
                    local sign = "+"
                    local mkw = vim.fn.strdisplaywidth(mk) -- the marker column: 1 cell (`➤` or a space)
                    local pw = vim.fn.strdisplaywidth(prefix) -- the original prefix's display width
                    local aprefix = string.rep(" ", mkw + 1)
                        .. sign
                        .. string.rep(" ", math.max(0, pw - (mkw + 1) - #sign))
                    local aline = aprefix .. body
                    local abr = push(aline, i)
                    hls[#hls + 1] = { abr, 0, -1, "LvimReplaceDiffAdd", 100 }
                    hls[#hls + 1] = { abr, mkw + 1, mkw + 1 + #sign, "LvimReplaceDiffAddSign", 160 }
                    hls[#hls + 1] = { abr, #aprefix, #aline, "LvimReplaceCode", 150 } -- the code text in yellow
                    for _, a in ipairs(adds) do
                        hls[#hls + 1] = { abr, #aprefix + a.c0, #aprefix + a.c1, "LvimReplaceReplace", 170 }
                    end
                end
            end
        end
        -- ACTIVE row: highlight EVERY line of the row under the cursor (a diff match owns two lines).
        if focused and sel ~= 1 then
            local sel_row = line_rows[sel]
            if sel_row then
                for bl = 2, #lines do
                    if line_rows[bl] == sel_row then
                        hls[#hls + 1] = { bl - 1, 0, -1, "LvimReplaceActiveRow", 205 }
                    end
                end
            end
        end
        return lines, hls
    end

    --- The result row under the results-layer cursor, or nil when the cursor is on the Mark bar / empty message
    --- (via the `S.line_rows` map, which survives the variable line-per-match count of the diff view).
    ---@return table?
    local function cursor_row()
        local idx = S.line_rows and S.line_rows[pan_sel(S.pan_results)]
        return idx and S.rows[idx] or nil
    end

    --- Move the results cursor to the FIRST line of the NEXT row (after marking) — skips a diff match's own
    --- replacement line, landing on the next match/file.
    local function advance()
        local pan = S.pan_results
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        local lr = S.line_rows or {}
        local cur = api.nvim_win_get_cursor(pan.win)[1]
        local here = lr[cur]
        for bl = cur + 1, #lr do
            if lr[bl] and lr[bl] ~= here then
                pcall(api.nvim_win_set_cursor, pan.win, { bl, 0 })
                return
            end
        end
    end

    --- Keep the results cursor OFF the non-interactive Mark bar (buffer row 1): if it lands there (initial
    --- focus, a mouse click, k past the top), step it down to the first content line.
    local function keep_off_bar()
        local pan = S.pan_results
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        if #S.rows > 0 and api.nvim_win_get_cursor(pan.win)[1] < 2 then
            pcall(api.nvim_win_set_cursor, pan.win, { 2, 0 })
        end
    end

    -- ── refresh ────────────────────────────────────────────────────────────────────

    --- Re-render every layer. Cheap — each panel repaints its own buffer (the toggles layer carries the
    --- live marked/total counter, so a mark/search change reflects there on the next paint).
    local function refresh_all()
        for _, pan in ipairs({ S.pan_inputs, S.pan_toggles, S.pan_results }) do
            if pan and pan.refresh then
                pcall(pan.refresh)
            end
        end
    end

    -- ── search driving ───────────────────────────────────────────────────────────

    local function do_search()
        if S.search_cancel then
            pcall(S.search_cancel)
            S.search_cancel = nil
        end
        S.err = nil
        if #(S.search or "") < config.min_chars then
            S.results = { files = {}, index = {}, count = 0 }
            S.searching = false
            refresh_all()
            return
        end
        S.searching = true
        S.results = { files = {}, index = {}, count = 0 }
        refresh_all()
        S.search_cancel = search.run(S, function(acc)
            if S.closed then
                return
            end
            S.results = acc
            refresh_all()
        end, function(acc, err)
            if S.closed then
                return
            end
            S.results = acc
            S.err = err
            S.searching = false
            S.search_cancel = nil
            refresh_all()
        end)
    end

    function S.schedule_search()
        if S.debounce then
            S.debounce:stop()
            if not S.debounce:is_closing() then
                S.debounce:close()
            end
        end
        S.debounce = vim.uv.new_timer()
        S.debounce:start(config.debounce or 200, 0, function()
            vim.schedule(function()
                if not S.closed then
                    do_search()
                end
            end)
        end)
    end

    -- ── flag toggles ─────────────────────────────────────────────────────────────

    function S.toggle_case()
        local order = { smart = "ignore", ignore = "sensitive", sensitive = "smart" }
        S.flags.case = order[S.flags.case] or "smart"
        refresh_all()
        do_search()
    end
    function S.toggle_word()
        S.flags.whole_word = not S.flags.whole_word
        refresh_all()
        do_search()
    end
    function S.toggle_regex()
        S.flags.regex = not S.flags.regex
        refresh_all()
        do_search()
    end
    function S.toggle_hidden()
        S.flags.hidden = not S.flags.hidden
        refresh_all()
        do_search()
    end

    -- ── marking ────────────────────────────────────────────────────────────────────

    local function mark_toggle()
        local row = cursor_row()
        if not row then
            return
        end
        if row.kind == "match" then
            S.marked[row.id] = (not S.marked[row.id]) or nil
        else
            local ids = file_match_ids(row)
            local all = is_marked(row)
            for _, id in ipairs(ids) do
                S.marked[id] = (not all) or nil
            end
        end
        refresh_all()
        advance()
    end

    function S.mark_all()
        for _, row in ipairs(S.rows) do
            if row.kind == "match" then
                S.marked[row.id] = true
            end
        end
        refresh_all()
    end

    function S.unmark_all()
        S.marked = {}
        refresh_all()
    end

    -- ── navigation to a match ────────────────────────────────────────────────────

    ---@return integer win
    local function target_win()
        local self = S.pan_results and S.pan_results.win
        local w = S.opener
        if w and api.nvim_win_is_valid(w) and w ~= self and api.nvim_win_get_config(w).relative == "" then
            return w
        end
        for _, win in ipairs(api.nvim_list_wins()) do
            if win ~= self and api.nvim_win_get_config(win).relative == "" then
                return win
            end
        end
        vim.cmd("vsplit")
        return api.nvim_get_current_win()
    end

    function S.goto_match()
        local row = cursor_row()
        if not row then
            return
        end
        local path, lnum, col
        if row.kind == "file" then
            local first = (S.results.files[row.gi].matches or {})[1]
            path, lnum, col = row.path, (first and first.lnum) or 1, 1
        else
            path, lnum, col = row.path, row.lnum, (row.spans[1] and row.spans[1].s or 0) + 1
        end
        local abs = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
        api.nvim_set_current_win(target_win())
        vim.cmd("edit " .. vim.fn.fnameescape(abs))
        pcall(api.nvim_win_set_cursor, 0, { lnum, math.max(0, col - 1) })
    end

    local function to_quickfix()
        local any = marked_count() > 0
        local qf = {}
        for _, row in ipairs(S.rows) do
            if row.kind == "match" and (not any or S.marked[row.id]) then
                qf[#qf + 1] = {
                    filename = vim.fs.normalize(vim.fn.fnamemodify(row.path, ":p")),
                    lnum = row.lnum,
                    col = (row.spans[1] and row.spans[1].s or 0) + 1,
                    text = row.text,
                }
            end
        end
        if #qf == 0 then
            return
        end
        vim.fn.setqflist({}, " ", { title = "LvimReplace", items = qf })
        vim.cmd("botright copen")
    end

    -- ── apply / undo ─────────────────────────────────────────────────────────────

    --- The MARKED matches to replace (marking is REQUIRED — apply never touches an unmarked match; to replace
    --- everything, Mark all first).
    ---@return table[] targets, integer files
    local function apply_targets()
        local out, files = {}, {}
        for _, row in ipairs(S.rows) do
            if row.kind == "match" and S.marked[row.id] then
                out[#out + 1] = { path = row.path, lnum = row.lnum, text = row.text, spans = row.spans }
                files[row.path] = true
            end
        end
        return out, vim.tbl_count(files)
    end

    local function do_apply()
        if marked_count() == 0 then
            vim.notify("lvim-replace: nothing marked — mark results (or Mark all) first", vim.log.levels.WARN)
            return
        end
        local targets, files = apply_targets()
        local n = #targets
        local function run()
            local res = apply.apply(targets, S.replace or "")
            store.add_history(S)
            local extra = res.skipped > 0 and (", " .. res.skipped .. " skipped (changed since search)") or ""
            vim.notify(
                ("lvim-replace: replaced %d match(es) in %d file(s)%s"):format(res.changed, res.files, extra),
                vim.log.levels.INFO
            )
            do_search()
        end
        if n >= (config.confirm_apply or 1) then
            require("lvim-ui").confirm({
                prompt = ("Replace %d MARKED match(es) in %d file(s)?"):format(n, files),
                callback = function(yes)
                    if yes then
                        run()
                    end
                end,
            })
        else
            run()
        end
    end

    local function do_undo()
        if not apply.can_undo() then
            vim.notify("lvim-replace: nothing to undo", vim.log.levels.INFO)
            return
        end
        local r = apply.undo()
        if r then
            vim.notify(("lvim-replace: reverted %d file(s)"):format(r.files), vim.log.levels.INFO)
        end
        do_search()
    end

    -- ── history / named searches ─────────────────────────────────────────────────

    ---@param snap { search: string, replace: string, paths: string, flags_extra: string, flags: table }
    local function load_snapshot(snap)
        S.search, S.replace, S.paths, S.flags_extra = snap.search, snap.replace, snap.paths, snap.flags_extra
        S.flags = snap.flags
        inputs_rewrite() -- the inputs buffer is editable; re-assert its field lines from the snapshot
        refresh_all()
        do_search()
    end

    local function open_history()
        local rows = store.history()
        local named = store.named()
        local items = {}
        for _, r in ipairs(named) do
            items[#items + 1] = { label = ("★ %s  —  %s → %s"):format(r.name, r.search, r.repl or ""), _row = r }
        end
        for _, r in ipairs(rows) do
            items[#items + 1] = { label = ("%s → %s  (%s)"):format(r.search, r.repl or "", r.files or ""), _row = r }
        end
        if #items == 0 then
            vim.notify("lvim-replace: no saved searches yet", vim.log.levels.INFO)
            return
        end
        require("lvim-ui").select({
            title = "Search History",
            items = items,
            callback = function(confirmed, index)
                if confirmed and items[index] then
                    load_snapshot(store.to_state(items[index]._row))
                end
            end,
        })
    end

    local function save_search()
        require("lvim-ui").input({
            title = "Save search as",
            prompt = "Name: ",
            callback = function(confirmed, name)
                if confirmed and name and name ~= "" and store.save_named(name, S) then
                    vim.notify("lvim-replace: saved search '" .. name .. "'", vim.log.levels.INFO)
                end
            end,
        })
    end

    -- ── help ─────────────────────────────────────────────────────────────────────

    --- The keymap cheatsheet — through the canonical help-popup module (`lvim-ui.help`): a striped, auto-sized
    --- key/description window (q/Esc close) exactly like the outline's, not a hand-rolled float.
    local function show_help()
        local k = config.keys
        local function lbl(v)
            return table.concat(keylist(v), " / ")
        end
        --- The plain footer key (strip a `<localleader>` prefix / the `<>` wrapper) — `<localleader>r` → `r`.
        ---@param v string|string[]
        ---@return string
        local function pk(v)
            return ((keylist(v)[1] or ""):gsub("<[Ll]ocalleader>", ""):gsub("[<>]", ""))
        end
        local items = {
            { "<C-j> / <C-k>", "next / previous sector (Inputs · Toggles · Results · footer)" },
            { "<C-h> / <C-l>", "jump out to the editor beside the panel" },
            { "<CR> / <Tab>", "Inputs: next field   ·   <S-Tab> previous field" },
            { "h / l", "Toggles: pick a flag   ·   <CR> / <Space> flip it" },
            { lbl(k.goto_match), "Results: jump to the match under the cursor" },
            { lbl(k.mark), "Results: mark / unmark the match, then advance" },
            { "m / n", "mark all / unmark all" },
            { pk(k.apply), "replace the marked matches" },
            { pk(k.undo), "undo the last replace" },
            { lbl(k.quickfix), "send results to the quickfix list" },
            {
                table.concat(
                    { lbl(k.toggle_case), lbl(k.toggle_word), lbl(k.toggle_regex), lbl(k.toggle_hidden) },
                    " "
                ),
                "case / whole-word / regex / hidden",
            },
            { lbl(k.history) .. " / " .. lbl(k.save_search), "search history / save this search" },
            { lbl(k.help), "this help" },
            { pk(k.close), "close the panel" },
        }
        require("lvim-ui").help({ title = "LvimReplace — keys", items = items })
    end

    -- ── a hide-cursor layer provider (toggles + results) ──────────────────────────

    --- Build a HIDE-CURSOR layer's content provider. `build(width)` returns `lines, hls`; `wire(map, pan)`
    --- binds the layer's keys; the layer re-renders as its hidden cursor moves (so the active row / button
    --- follows). `slot` names where to stash the panel handle on `S`. (The inputs layer is editable, so it
    --- has its own provider below, not this one.)
    ---@param slot string
    ---@param build fun(width: integer): string[], table[]
    ---@param wire fun(map: fun(lhs: string|string[], fn: fun()), pan: table)
    ---@return table
    local function make_layer(slot, build, wire)
        return {
            hide_cursor = true,
            filetype = "lvim-replace",
            update = function(pan)
                S[slot] = pan
                local width = (pan.win and api.nvim_win_is_valid(pan.win)) and api.nvim_win_get_width(pan.win) or 80
                local lines, hls = build(width)
                surface.paint(pan, lines, hls)
            end,
            keys = function(map, pan)
                S[slot] = pan
                wire(map, pan)
                -- The active row / button follows the hidden cursor (CursorMoved) AND only shows in the focused
                -- sector (WinEnter/WinLeave) — so entering a sector lights its active row and leaving it clears
                -- it. WinLeave is scheduled so the repaint runs AFTER focus has actually moved off this window.
                local grp = api.nvim_create_augroup("LvimReplace_" .. slot .. "_" .. pan.buf, { clear = true })
                api.nvim_create_autocmd("CursorMoved", {
                    group = grp,
                    buffer = pan.buf,
                    callback = function()
                        if pan.refresh then
                            pan.refresh()
                        end
                    end,
                })
                api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
                    group = grp,
                    buffer = pan.buf,
                    callback = function()
                        vim.schedule(function()
                            if pan.refresh then
                                pan.refresh()
                            end
                        end)
                    end,
                })
                S.augroups = S.augroups or {}
                S.augroups[#S.augroups + 1] = grp
            end,
        }
    end

    -- The INPUTS layer is a REAL editable buffer (inline editing): the chassis makes the window, we own the
    -- buffer via `update` (write the four field lines once, then only re-style so typing is never clobbered),
    -- and a TextChanged autocmd syncs the values into `S` + debounces the search.
    local inputs_provider = {
        editable = true,
        cursorline = false,
        filetype = "lvim-replace",
        update = function(pan)
            S.pan_inputs = pan
            if not S.inputs_init then
                S.inputs_init = true
                inputs_rewrite()
            else
                apply_field_styling(pan.buf) -- a resize / refresh: re-assert the styling, keep the typed text
            end
        end,
        keys = function(map, pan)
            S.pan_inputs = pan
            -- Inline editing means a REAL cursor here — but only while TYPING. In normal / visual mode the
            -- hardware cursor is hidden (like every other sector), so leaving insert never parks a stray block
            -- cursor at column 0. `mark_cursor_buffer` applies this per-mode `guicursor` fragment whenever the
            -- inputs buffer is current; insert keeps the baseline (visible) cursor.
            cursor.mark_cursor_buffer(pan.buf, "n-v-c:ver1-LvimUtilsHiddenCursor")
            local grp = api.nvim_create_augroup("LvimReplaceInputs_" .. pan.buf, { clear = true })
            api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
                group = grp,
                buffer = pan.buf,
                callback = sync_fields,
            })
            S.augroups = S.augroups or {}
            S.augroups[#S.augroups + 1] = grp

            -- Insert-mode: keep the field region exactly FIELD_COUNT lines — <CR> / <Tab> move between fields,
            -- <S-Tab> back; a backspace / word-delete / line-kill at column 1 is a no-op (never joins the line
            -- above). Normal-mode: block the structure-changing motions (join / open-line / multiline paste).
            local function move_field(delta)
                local win = S.pan_inputs and S.pan_inputs.win
                if not (win and api.nvim_win_is_valid(win)) then
                    return
                end
                local cur = api.nvim_win_get_cursor(win)[1]
                local dest = cur + delta
                if dest >= 1 and dest <= FIELD_COUNT then
                    local eol = #(api.nvim_buf_get_lines(pan.buf, dest - 1, dest, false)[1] or "")
                    pcall(api.nvim_win_set_cursor, win, { dest, eol })
                end
            end
            vim.keymap.set("i", "<CR>", function()
                move_field(1)
            end, { buffer = pan.buf, nowait = true, silent = true })
            vim.keymap.set("i", "<Tab>", function()
                move_field(1)
            end, { buffer = pan.buf, nowait = true, silent = true })
            vim.keymap.set("i", "<S-Tab>", function()
                move_field(-1)
            end, { buffer = pan.buf, nowait = true, silent = true })
            local function guard_bol(key)
                return function()
                    return vim.fn.col(".") == 1 and "" or key
                end
            end
            for _, key in ipairs({ "<BS>", "<C-w>", "<C-u>" }) do
                vim.keymap.set("i", key, guard_bol(key), {
                    buffer = pan.buf,
                    expr = true,
                    replace_keycodes = true,
                    nowait = true,
                    silent = true,
                })
            end
            map("J", function() end)
            map("o", function() end)
            map("O", function() end)
        end,
    }

    local toggles_provider = make_layer("pan_toggles", toggles_lines, function(map)
        map({ "l", "<Right>" }, function()
            toggle_move(1)
        end)
        map({ "h", "<Left>" }, function()
            toggle_move(-1)
        end)
        map(config.keys.goto_match, toggles_activate)
        map("<Space>", toggles_activate)
    end)

    local results_provider = make_layer("pan_results", results_lines, function(map, pan)
        local k = config.keys
        map(k.goto_match, S.goto_match)
        map(k.mark, mark_toggle)
        -- Keep the cursor off the non-interactive Mark bar (row 1), on entry and on every move.
        local grp = api.nvim_create_augroup("LvimReplaceResultsBar_" .. pan.buf, { clear = true })
        api.nvim_create_autocmd({ "CursorMoved", "WinEnter" }, {
            group = grp,
            buffer = pan.buf,
            callback = keep_off_bar,
        })
        S.augroups = S.augroups or {}
        S.augroups[#S.augroups + 1] = grp
    end)

    -- ── the surface (a vertical stack of layer sectors, docked right) ─────────────

    local k = config.keys
    --- The PLAIN footer key for `v` — the bare letter after `<localleader>` (e.g. `<localleader>r` → `r`).
    --- This is BOTH the button label AND a real frame-wide keymap, so the shown key is the key you press.
    --- (`<localleader>` is stripped entirely, never expanded to the leader char — expanding it is what made the
    --- "plain" key bind to `<leader-char>r` instead of `r`.)
    ---@param v string|string[]
    ---@return string
    local function fk(v)
        local first = keylist(v)[1] or ""
        return (first:gsub("<[Ll]ocalleader>", ""):gsub("[<>]", ""))
    end

    -- Per-sector chrome from `config.sectors`. `border` is the ring; `separator` (inputs / toggles) is a rule
    -- UNDER the sector — a bottom-only border edge (no ring above / at the sides), so each boundary is
    -- controlled independently by the sector above it. The global divider is off (`separator = false` below).
    local sectors = config.sectors or {}
    --- Resolve a sector's border spec: "none" + separator → a bottom rule; a real ring already has its bottom
    --- edge, so it is returned untouched.
    ---@param spec { border?: string|string[], separator?: boolean }|nil
    ---@return string|string[]
    local function sector_border(spec)
        spec = spec or {}
        local b = spec.border or "none"
        if b == "none" then
            return spec.separator and { "", "", "", "", "", "─", "", "" } or "none"
        end
        return b
    end
    local inputs_border = sector_border(sectors.inputs)
    local toggles_border = sector_border(sectors.toggles)
    local results_border = sector_border(sectors.results)

    S.st = surface.open({
        mode = "split",
        dock = "right",
        direction = "vertical", -- the three layers STACK top→bottom
        center_panel_sectors = true, -- each layer is its OWN <C-j>/<C-k> sector
        enter = true,
        size = { width = { fixed = config.width or 0.5 } },
        title = base_title,
        normal_hl = "LvimReplaceNormal",
        separator = false, -- the per-sector separators are the sectors' own bottom borders, not a global rule
        content = {
            blocks = {
                -- `size.height.fixed` is the sector's CONTENT rows — the border (a ring, or the separator's
                -- bottom rule) reserves its own row on top of it, so each sector hugs its content.
                {
                    id = "inputs",
                    provider = inputs_provider,
                    border = inputs_border,
                    size = { height = { fixed = FIELD_COUNT } },
                },
                {
                    id = "toggles",
                    provider = toggles_provider,
                    border = toggles_border,
                    size = { height = { auto = true } }, -- one row — auto-fit to the single toggle line
                },
                { id = "results", provider = results_provider, border = results_border },
            },
        },
        close_keys = { fk(k.close) }, -- ONLY `q` closes the panel — `<Esc>` just leaves insert in the inputs
        -- The footer actions fire from ANY sector (frame-wide keymaps): the PLAIN keys shown on the buttons
        -- (`r`/`u`/`g?`/`q`, plus `m`/`n` for mark/unmark) AND the `<localleader>` aliases both trigger them, so
        -- they work whether the cursor is in the inputs (normal mode), the toggles or the results.
        keymaps = {
            { key = { fk(k.apply), k.apply }, run = do_apply },
            { key = { fk(k.undo), k.undo }, run = do_undo },
            { key = { fk(k.help), k.help }, run = show_help },
            {
                key = { fk(k.close), k.close },
                run = function()
                    M.close()
                end,
            },
            { key = { "m", k.mark_all }, run = S.mark_all },
            { key = { "n", k.unmark_all }, run = S.unmark_all },
            { key = k.quickfix, run = to_quickfix },
            { key = k.toggle_case, run = S.toggle_case },
            { key = k.toggle_word, run = S.toggle_word },
            { key = k.toggle_regex, run = S.toggle_regex },
            { key = k.toggle_hidden, run = S.toggle_hidden },
            { key = k.history, run = open_history },
            { key = k.save_search, run = save_search },
        },
        footer = {
            bars = {
                {
                    align = "center",
                    items = {
                        surface.button(
                            { name = "replace", key = fk(k.apply), style = "action", run = do_apply },
                            "action"
                        ),
                        surface.button({ name = "undo", key = fk(k.undo), style = "action", run = do_undo }, "action"),
                        surface.button(
                            { name = "qf", key = fk(k.quickfix), style = "action", run = to_quickfix },
                            "action"
                        ),
                        surface.button(
                            { name = "help", key = fk(k.help), style = "action", run = show_help },
                            "action"
                        ),
                        surface.button({
                            name = "close",
                            key = fk(k.close),
                            style = "action",
                            run = function()
                                M.close()
                            end,
                        }, "action"),
                    },
                },
            },
        },
        on_close = function()
            S.closed = true
            if S.search_cancel then
                pcall(S.search_cancel)
                S.search_cancel = nil
            end
            if S.debounce then
                S.debounce:stop()
                if not S.debounce:is_closing() then
                    S.debounce:close()
                end
                S.debounce = nil
            end
            for _, grp in ipairs(S.augroups or {}) do
                pcall(api.nvim_del_augroup_by_id, grp)
            end
            S.augroups = nil
            apply.reset()
            if current and current.state == S then
                current = nil
            end
        end,
    })

    current = {
        state = S,
        close = function()
            if S.st and S.st.close then
                pcall(S.st.close)
            end
        end,
        focus = function()
            if S.pan_inputs and S.pan_inputs.win and api.nvim_win_is_valid(S.pan_inputs.win) then
                api.nvim_set_current_win(S.pan_inputs.win)
            end
        end,
        apply_prefills = function(o)
            if not (o.prefills or o.scope_paths) then
                return
            end
            S.scope_paths = o.scope_paths or S.scope_paths
            load_snapshot({
                search = (o.prefills or {}).search or S.search,
                replace = (o.prefills or {}).replace or S.replace,
                paths = (o.prefills or {}).paths or S.paths,
                flags_extra = (o.prefills or {}).flags_extra or S.flags_extra,
                flags = S.flags,
            })
        end,
    }

    -- Land on the Inputs layer, on the Search row in insert (a search-first flow), and run any prefill search.
    vim.schedule(function()
        if S.closed then
            return
        end
        if S.st and S.st.focus_block then
            pcall(S.st.focus_block, "inputs")
        end
        if S.pan_inputs and S.pan_inputs.win and api.nvim_win_is_valid(S.pan_inputs.win) then
            api.nvim_set_current_win(S.pan_inputs.win)
            pcall(api.nvim_win_set_cursor, S.pan_inputs.win, { 1, #(S.search or "") })
            vim.cmd("startinsert!")
        end
        if (S.search or "") ~= "" then
            do_search()
        end
    end)
end

--- Close the panel.
function M.close()
    if current then
        current.close()
    end
end

--- Whether the panel is open.
---@return boolean
function M.is_open()
    return current ~= nil
end

--- Toggle the panel.
---@param opts? table
function M.toggle(opts)
    if M.is_open() then
        M.close()
    else
        M.open(opts)
    end
end

return M
