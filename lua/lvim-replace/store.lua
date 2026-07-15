-- lvim-replace.store: SQLite persistence for search HISTORY and named SAVED searches, through the shared
-- lvim-utils.store wrapper (backend = "sqlite", versioned via PRAGMA user_version — the set's persistence
-- canon). Own database file under stdpath("data")/lvim-replace — never a central DB, never anything written
-- inside the user's repositories. Persistence is OPT-OUT (`config.persist`); when sqlite.lua is absent the
-- callers degrade gracefully (history/named simply do nothing) — the search & replace core never needs it.
--
---@module "lvim-replace.store"

local config = require("lvim-replace.config")

local M = {}

-- Bump together with a matching MIGRATIONS step on any schema change; a fresh db is stamped at the current
-- version directly (no steps run).
---@type integer
local SCHEMA_VERSION = 1

-- A search snapshot's columns, shared by both tables (the four fields + the flag state).
---@type table<string, table>
local SNAPSHOT_COLUMNS = {
    search = { "text" },
    -- "repl" (not "replace"): REPLACE is a SQL reserved keyword and breaks INSERT.
    repl = { "text" },
    files = { "text" },
    flags = { "text" },
    -- "casing" (not "case"): CASE is a SQL reserved keyword and breaks the CREATE TABLE.
    casing = { "text" },
    whole_word = { "integer" },
    regex = { "integer" },
    multiline = { "integer" },
    hidden = { "integer" },
    no_ignore = { "integer" },
}

--- Merge the shared snapshot columns into a base column spec.
---@param base table<string, table>
---@return table<string, table>
local function with_snapshot(base)
    return vim.tbl_extend("force", base, SNAPSHOT_COLUMNS)
end

---@type table<string, table>
local TABLES = {
    -- Recent searches, appended on a successful apply; pruned to config.max_history newest.
    history = with_snapshot({
        id = { "integer", primary = true, autoincrement = true },
        ts = { "integer" },
    }),
    -- Named searches the user saved on purpose (kept until deleted).
    named = with_snapshot({
        id = { "integer", primary = true, autoincrement = true },
        name = { "text", required = true },
        updated = { "integer" },
    }),
}

---@type table<integer, fun(db: table)>
local MIGRATIONS = {}

---@type table?  the lazily opened store handle
local handle

--- Whether the sqlite backend is available (sqlite.lua installed) AND persistence is enabled.
---@return boolean
function M.available()
    return config.persist ~= false and require("lvim-utils.store").available()
end

--- The (lazily opened) store handle, or nil when persistence is off / unavailable.
---@return table?
function M.get()
    if not M.available() then
        return nil
    end
    if handle then
        return handle
    end
    local dir = config.save or (vim.fn.stdpath("data") .. "/lvim-replace")
    handle = require("lvim-utils.store").new({
        backend = "sqlite",
        name = "lvim-replace",
        dir = vim.fs.normalize(dir),
        version = SCHEMA_VERSION,
        tables = TABLES,
        migrations = MIGRATIONS,
    })
    return handle
end

--- A row (for insert) from the live panel state's fields + flag toggles.
---@param st table
---@return table
local function snapshot(st)
    local f = st.flags
    local function b(v)
        return v and 1 or 0
    end
    return {
        search = st.search or "",
        repl = st.replace or "",
        files = st.paths or "",
        flags = st.flags_extra or "",
        casing = f.case,
        whole_word = b(f.whole_word),
        regex = b(f.regex),
        multiline = b(f.multiline),
        hidden = b(f.hidden),
        no_ignore = b(f.no_ignore),
    }
end

--- Apply a stored row back onto a fresh flag table (integers → booleans). Used when loading history/named.
---@param row table
---@return { search: string, replace: string, paths: string, flags_extra: string, flags: table }
function M.to_state(row)
    return {
        search = row.search or "",
        replace = row.repl or "",
        paths = row.files or "",
        flags_extra = row.flags or "",
        flags = {
            case = row.casing or "smart",
            whole_word = (row.whole_word or 0) == 1,
            regex = (row.regex or 0) == 1,
            multiline = (row.multiline or 0) == 1,
            hidden = (row.hidden or 0) == 1,
            no_ignore = (row.no_ignore or 0) == 1,
        },
    }
end

--- Append the current search to history (deduping an identical most-recent entry), then prune to the
--- newest `config.max_history`. A no-op without persistence or an empty search.
---@param st table
function M.add_history(st)
    local s = M.get()
    if not s or (st.search or "") == "" then
        return
    end
    local rows = s:find("history") or {}
    local last = rows[#rows]
    if last and last.search == st.search and last.repl == st.replace and last.files == (st.paths or "") then
        return -- identical to the most recent — do not duplicate
    end
    local row = snapshot(st)
    row.ts = os.time()
    s:insert("history", row)
    -- Prune oldest beyond the cap.
    rows = s:find("history") or {}
    local cap = tonumber(config.max_history) or 50
    if #rows > cap then
        table.sort(rows, function(a, b)
            return (a.ts or 0) < (b.ts or 0)
        end)
        for i = 1, #rows - cap do
            s:remove("history", { id = rows[i].id })
        end
    end
end

--- Every history row, newest first.
---@return table[]
function M.history()
    local s = M.get()
    if not s then
        return {}
    end
    local rows = s:find("history") or {}
    table.sort(rows, function(a, b)
        return (a.ts or 0) > (b.ts or 0)
    end)
    return rows
end

--- Save (or overwrite) a named search from the current state.
---@param name string
---@param st table
---@return boolean
function M.save_named(name, st)
    local s = M.get()
    if not s or name == "" then
        return false
    end
    local row = snapshot(st)
    row.name = name
    row.updated = os.time()
    local existing = s:find("named", { name = name }) or {}
    if existing[1] then
        return s:update("named", { id = existing[1].id }, row) ~= false
    end
    return s:insert("named", row) ~= false
end

--- Every named search, newest first.
---@return table[]
function M.named()
    local s = M.get()
    if not s then
        return {}
    end
    local rows = s:find("named") or {}
    table.sort(rows, function(a, b)
        return (a.updated or 0) > (b.updated or 0)
    end)
    return rows
end

--- Delete a named search by id.
---@param id integer
---@return boolean
function M.delete_named(id)
    local s = M.get()
    if not s then
        return false
    end
    return s:remove("named", { id = id }) ~= false
end

--- The db file path (for :checkhealth), or nil.
---@return string?
function M.path()
    local s = M.get()
    return s and s:path() or nil
end

--- The on-disk schema version (for :checkhealth).
---@return integer
function M.schema_version()
    local s = M.get()
    if not s then
        return 0
    end
    local rows = s:exec("PRAGMA user_version")
    if type(rows) == "table" and rows[1] and rows[1].user_version ~= nil then
        return tonumber(rows[1].user_version) or 0
    end
    return 0
end

--- Close the handle (tests / teardown).
function M.close()
    if handle then
        handle:close()
        handle = nil
    end
end

return M
