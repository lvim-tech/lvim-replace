-- lvim-replace.apply: write the replacement to disk for the MARKED results only, with batch undo.
-- The selective-apply seam is the plugin's headline feature: apply operates on the exact set of result
-- LINES the user marked (or all results when none are marked), never a whole-file `rg --replace`. Each
-- marked line carries the byte spans + ripgrep's own replacement text (`after`) captured at search time,
-- so applying is a pure, deterministic splice — right-to-left per line so earlier spans keep their offsets.
--
-- SAFETY: before splicing a line the engine verifies the file's CURRENT line still equals the text seen at
-- search time; a line changed since the search is SKIPPED (never corrupted) and reported. A loaded buffer is
-- edited THROUGH the buffer (set lines + `:write`) so its own undo history and any listeners stay intact;
-- an unopened file is written directly. Every applied batch snapshots the pre-change content, so `undo`
-- restores the whole batch (buffer or disk) in one step.
--
---@module "lvim-replace.apply"

local M = {}

---@class LvimReplaceUndoEntry
---@field path string          absolute path
---@field bufnr integer?       the loaded buffer (edited through it) or nil (written to disk)
---@field before string[]      the pre-apply lines (restored on undo)

---@type LvimReplaceUndoEntry[][]  the undo stack: each element is one applied batch
local undo_stack = {}

--- Splice every span of `line` with its replacement (right-to-left so earlier spans keep their byte
--- offsets). `fallback` is used when a span has no ripgrep `after` (a delete, i.e. an empty Replace).
---@param line string
---@param spans { s: integer, e: integer, after: string? }[]
---@param fallback string
---@return string
local function splice(line, spans, fallback)
    local ordered = vim.deepcopy(spans)
    table.sort(ordered, function(a, b)
        return a.s > b.s
    end)
    for _, sp in ipairs(ordered) do
        local rep = sp.after ~= nil and sp.after or fallback
        line = line:sub(1, sp.s) .. rep .. line:sub(sp.e + 1)
    end
    return line
end

--- Read a file's lines from the loaded buffer when present (so the change layers on unsaved edits and
--- the buffer stays authoritative), else from disk.
---@param path string  absolute path
---@return string[] lines, integer? bufnr
local function read_lines(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
    end
    if vim.fn.filereadable(path) == 1 then
        return vim.fn.readfile(path), nil
    end
    return {}, nil
end

--- Write `lines` back to `path`: through the buffer (set lines + silent write) when loaded, else to disk.
---@param path string
---@param bufnr integer?
---@param lines string[]
local function write_lines(path, bufnr, lines)
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent! keepjumps write")
        end)
    else
        vim.fn.writefile(lines, path)
    end
end

--- Apply the replacement to `entries` (each a marked result line). Groups by file, verifies each line is
--- unchanged since the search, splices the marked lines, writes every touched file and pushes one undo
--- batch. `fallback` is the Replace value used for spans without a ripgrep `after` (an empty Replace = a
--- delete). Returns a summary for the caller to report.
---@param entries { path: string, lnum: integer, text: string, spans: table[] }[]
---@param fallback string
---@return { changed: integer, skipped: integer, files: integer }
function M.apply(entries, fallback)
    -- Group by absolute path, mapping line number → entry (a line is marked at most once).
    ---@type table<string, { lnum: integer, text: string, spans: table[] }[]>
    local by_file = {}
    local order = {}
    for _, e in ipairs(entries) do
        local abs = vim.fs.normalize(vim.fn.fnamemodify(e.path, ":p"))
        if not by_file[abs] then
            by_file[abs] = {}
            order[#order + 1] = abs
        end
        table.insert(by_file[abs], e)
    end

    local batch = {}
    local changed, skipped = 0, 0
    for _, abs in ipairs(order) do
        local lines, bufnr = read_lines(abs)
        if #lines > 0 then
            local before = vim.deepcopy(lines)
            local touched = false
            for _, e in ipairs(by_file[abs]) do
                local cur = lines[e.lnum]
                if cur == nil or cur ~= e.text then
                    skipped = skipped + 1 -- the line changed since the search — never corrupt it
                else
                    lines[e.lnum] = splice(cur, e.spans, fallback)
                    changed = changed + 1
                    touched = true
                end
            end
            if touched then
                write_lines(abs, bufnr, lines)
                batch[#batch + 1] = { path = abs, bufnr = bufnr, before = before }
            end
        else
            skipped = skipped + #by_file[abs]
        end
    end

    if #batch > 0 then
        undo_stack[#undo_stack + 1] = batch
    end
    return { changed = changed, skipped = skipped, files = #batch }
end

--- Whether there is an applied batch to undo.
---@return boolean
function M.can_undo()
    return #undo_stack > 0
end

--- Restore the most recent applied batch (buffer or disk), removing it from the undo stack.
---@return { files: integer }?  a summary, or nil when nothing to undo
function M.undo()
    local batch = table.remove(undo_stack)
    if not batch then
        return nil
    end
    for _, entry in ipairs(batch) do
        write_lines(entry.path, entry.bufnr, entry.before)
    end
    return { files = #batch }
end

--- Drop the undo history (called on panel close so a stale batch never lingers across sessions).
function M.reset()
    undo_stack = {}
end

return M
