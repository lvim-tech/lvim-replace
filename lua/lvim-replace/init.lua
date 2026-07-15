-- lvim-replace: a project-wide find & replace tool (a clean-room, ripgrep-powered replica of the
-- find-and-replace UX) built on the lvim-tech ecosystem. `setup()` merges user options into the LIVE
-- config, registers the self-theming highlight factory and the single `:LvimReplace` command; the panel
-- itself (the surface chassis, the ripgrep streaming, the selective apply) lives in the submodules.
--
-- The distinguishing feature over the tools it replaces is SELECTIVE APPLY: every result is markable, the
-- top bar carries mark-all / unmark-all, and a replace writes ONLY the marked matches (or all when none are
-- marked, after a confirm). See lvim-replace.ui for the marking + apply seam.
--
---@module "lvim-replace"

local config = require("lvim-replace.config")
local highlights = require("lvim-replace.highlights")

local M = {}

---@type boolean  guards the one-time command / highlight registration
local registered = false

--- The current visual selection as a single string (charwise), for pre-filling the Search field.
---@return string
local function visual_selection()
    local mode = vim.fn.mode()
    local a, b
    if mode:match("[vV\022]") then
        a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
    else
        a, b = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    end
    local sl, sc, el, ec = a[2], a[3], b[2], b[3]
    if sl > el or (sl == el and sc > ec) then
        sl, sc, el, ec = el, ec, sl, sc
    end
    local lines = vim.api.nvim_buf_get_text(0, sl - 1, sc - 1, el - 1, ec, {})
    return table.concat(lines, "\n")
end

--- Open the find & replace panel.
---@param opts? table  see lvim-replace.ui.open (prefills / scope_paths / flags)
function M.open(opts)
    require("lvim-replace.ui").open(opts)
end

--- Toggle the panel.
---@param opts? table
function M.toggle(opts)
    require("lvim-replace.ui").toggle(opts)
end

--- Close the panel.
function M.close()
    require("lvim-replace.ui").close()
end

--- Open with the word under the cursor pre-filled as the Search term.
---@param opts? table
function M.open_cword(opts)
    opts = opts or {}
    opts.prefills = vim.tbl_extend("force", opts.prefills or {}, { search = vim.fn.expand("<cword>") })
    M.open(opts)
end

--- Open with the current visual selection pre-filled as the Search term.
---@param opts? table
function M.open_visual(opts)
    opts = opts or {}
    opts.prefills = vim.tbl_extend("force", opts.prefills or {}, { search = visual_selection() })
    M.open(opts)
end

--- Open limited to the CURRENT file (its path becomes the search scope).
---@param opts? table
function M.open_current_file(opts)
    opts = opts or {}
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= "" then
        opts.scope_paths = { vim.fs.normalize(vim.fn.fnamemodify(name, ":p")) }
    end
    M.open(opts)
end

-- :LvimReplace subcommands (also the completion source). There is only ONE view (a real split window), so
-- there is NO layout token — just the open/scope verbs.
---@type string[]
local SUBCOMMANDS = { "open", "toggle", "close", "file", "word", "selection" }

--- Dispatch `:LvimReplace [subcommand]`.
---@param cmd table  the nvim_create_user_command callback arg
local function dispatch(cmd)
    local sub = cmd.fargs[1]
    if sub == nil or sub == "open" then
        M.open()
    elseif sub == "toggle" then
        M.toggle()
    elseif sub == "close" then
        M.close()
    elseif sub == "file" then
        M.open_current_file()
    elseif sub == "word" then
        M.open_cword()
    elseif sub == "selection" then
        M.open_visual()
    else
        vim.notify("lvim-replace: unknown subcommand " .. sub, vim.log.levels.ERROR)
    end
end

--- Command completion: the subcommands.
---@param arglead string
---@return string[]
local function complete(arglead)
    local out = {}
    for _, c in ipairs(SUBCOMMANDS) do
        if c:find(arglead, 1, true) == 1 then
            out[#out + 1] = c
        end
    end
    return out
end

--- Merge user options into the LIVE config (in place) and register the command + highlight factory.
---@param opts? LvimReplaceConfig
function M.setup(opts)
    require("lvim-utils.utils").merge(config, opts or {})
    if registered then
        return
    end
    registered = true
    require("lvim-utils.highlight").bind(highlights.build)
    vim.api.nvim_create_user_command("LvimReplace", dispatch, {
        nargs = "*",
        range = true,
        complete = complete,
        desc = "lvim-replace: open | toggle | close | file | word | selection",
    })
end

return M
