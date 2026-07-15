-- lvim-replace: :checkhealth lvim-replace.
-- Reports the things that make a find & replace tool silently misbehave: ripgrep missing or too old
-- (the entire search + replace backend), the ecosystem deps the panel is built on, and the persistence
-- backend (sqlite.lua vs. history/named searches disabled). Read-only — it never mutates config or state.
--
---@module "lvim-replace.health"

local config = require("lvim-replace.config")
local search = require("lvim-replace.search")
local store = require("lvim-replace.store")

local M = {}

--- The installed ripgrep version as `major*100 + minor`, or 0 when absent / unparseable.
---@return integer
local function rg_version()
    if not search.has_rg() then
        return 0
    end
    local ok, out = pcall(vim.fn.systemlist, { "rg", "--version" })
    local maj, min = ((ok and out[1]) or ""):match("(%d+)%.(%d+)")
    return (maj and tonumber(maj) * 100 + tonumber(min)) or 0
end

--- Run the health report.
function M.check()
    local health = vim.health
    health.start("lvim-replace")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10 (vim.system, vim.json, extmark end_col)")
    else
        health.error("Neovim >= 0.10 is required")
    end

    -- ripgrep — the search AND replace engine.
    local ver = rg_version()
    if ver == 0 then
        health.error("ripgrep (rg) not found on PATH — search and replace cannot run")
    elseif ver < 1400 then
        health.warn(
            ("ripgrep %d.%d found — >= 14 recommended (JSON output + reliable --replace)"):format(
                math.floor(ver / 100),
                ver % 100
            )
        )
    else
        health.ok(("ripgrep %d.%d"):format(math.floor(ver / 100), ver % 100))
    end

    -- Ecosystem deps.
    local ok_ui = pcall(require, "lvim-ui.surface")
    local ok_utils, colors = pcall(require, "lvim-utils.colors")
    if ok_ui and ok_utils and type(colors.blend) == "function" then
        health.ok("lvim-ui + lvim-utils found (surface chassis + palette)")
    else
        health.error("lvim-ui / lvim-utils not found — the panel cannot render")
    end
    if pcall(require, "lvim-utils.icons") then
        health.ok("lvim-utils.icons found (file devicons in result headers)")
    else
        health.info("lvim-utils.icons unavailable — result headers show no file icons")
    end

    -- Persistence (history + named searches).
    if config.persist == false then
        health.info("persistence disabled (config.persist = false) — no history / named searches")
    elseif store.available() then
        health.ok("sqlite.lua found — history + named searches persisted at " .. (store.path() or "?"))
        health.info("schema version " .. tostring(store.schema_version()))
    else
        health.info(
            "sqlite.lua not installed — history + named searches are unavailable (search & replace still work)"
        )
    end

    -- Config sanity.
    local problems = 0
    if type(config.min_chars) ~= "number" or config.min_chars < 0 then
        health.error("min_chars must be a number >= 0")
        problems = problems + 1
    end
    if type(config.width) ~= "number" or config.width <= 0 then
        health.error(
            ("width must be a positive number (fraction <= 1 or columns > 1); got %s"):format(vim.inspect(config.width))
        )
        problems = problems + 1
    end
    if not vim.tbl_contains({ "smart", "ignore", "sensitive" }, (config.flags or {}).case) then
        health.error('flags.case must be "smart", "ignore" or "sensitive"')
        problems = problems + 1
    end
    if problems == 0 then
        health.ok("config valid")
    end
end

return M
