-- lvim-replace.config: the LIVE configuration table for the project-wide find & replace UI.
-- Holds the defaults; `setup()` merges user overrides into it IN PLACE (via lvim-utils.utils.merge),
-- so every `require("lvim-replace.config")` reader sees the effective values. Everything here is
-- read live by the search backend, the panel UI and the apply engine — no value is captured at
-- setup time, so a control-center toggle takes effect on the next open with no restart.
--
---@module "lvim-replace.config"

---@class LvimReplaceFlags
---@field case          "smart"|"ignore"|"sensitive"  Default case handling (rg --smart-case / -i / -s)
---@field whole_word    boolean                       Match whole words only (rg --word-regexp)
---@field regex         boolean                       Treat Search as a regex (false = literal --fixed-strings)
---@field multiline     boolean                       Enable multiline search (rg --multiline --multiline-dotall)
---@field hidden        boolean                       Search hidden files (rg --hidden)
---@field no_ignore     boolean                       Ignore .gitignore / .ignore (rg --no-ignore)

---@class LvimReplaceKeys
---@field goto_match    string|string[]  Open the result under the cursor at its file/line/column (normal)
---@field mark          string|string[]  Toggle the result under the cursor's mark, then advance (normal)
---@field mark_all      string|string[]  Mark every result
---@field unmark_all    string|string[]  Clear every mark
---@field apply         string|string[]  Apply the replacement to the marked results (or all when none marked)
---@field undo          string|string[]  Undo the last applied replacement batch
---@field quickfix      string|string[]  Send the marked results (or all) to the quickfix list
---@field toggle_regex  string|string[]  Toggle regex ↔ literal search
---@field toggle_case   string|string[]  Cycle the case mode (smart → ignore → sensitive)
---@field toggle_word   string|string[]  Toggle whole-word matching
---@field toggle_hidden string|string[]  Toggle searching hidden files
---@field history       string|string[]  Open the saved search history picker
---@field save_search   string|string[]  Save the current search to the named-searches store
---@field help          string|string[]  Open the keymap cheatsheet
---@field close         string|string[]  Close the panel

---@class LvimReplaceSector
---@field border?    string|string[]  Border for this sector — "none" | "rounded" | "single" | a custom 8-element table
---@field separator? boolean          (inputs / toggles only) draw a divider rule under this sector

---@class LvimReplaceSectors
---@field inputs  LvimReplaceSector  The Search / Replace / Files / Flags sector
---@field toggles LvimReplaceSector  The Case / Word / Regex / Hidden toggle bar
---@field results LvimReplaceSector  The results sector (Mark all / Unmark all bar + match list)

---@class LvimReplaceConfig
---@field width         number                   Split width — fraction of the screen (<= 1) or absolute columns (> 1)
---@field sectors       LvimReplaceSectors       Per-sector border + separator chrome
---@field min_chars     integer                  Minimum Search characters before ripgrep runs
---@field debounce      integer                  Milliseconds a field change is debounced before searching
---@field max_results   integer                  Cap on matching LINES shown (ripgrep is stopped past it)
---@field max_columns   integer                  ripgrep --max-columns (0 disables the per-line length cap)
---@field flags         LvimReplaceFlags         Default search flag state (each toggleable live)
---@field exclude       string[]                 Glob patterns always excluded (rg -g '!<glob>')
---@field confirm_apply integer                  Apply of ≥ this many matches asks for confirmation first
---@field marker        string                   The mark glyph in the results' front column
---@field persist       boolean                  Persist search history + named searches (SQLite)
---@field save          string?                  Store DIRECTORY (nil = stdpath("data")/lvim-replace)
---@field max_history   integer                  How many recent searches to keep
---@field keys          LvimReplaceKeys          Buffer-local panel keymaps
---@field hl            table<string, string>    Highlight-group name overrides

---@type LvimReplaceConfig
return {
    -- The panel is ONE view: a docked vertical SPLIT (never a float), a stack of three navigable sectors —
    -- Inputs · Toggles · Results. `width` is that split's width: a fraction of the screen (<= 1) or an
    -- absolute column count.
    width = 0.5,
    -- Per-sector chrome. `border` is any lvim-ui border spec ("none" | "rounded" | "single" | a custom
    -- 8-element table); the Inputs + Toggles sectors also take `separator` — a divider rule drawn UNDER them
    -- (between that sector and the next). The Results sector runs to the bottom, so it has no separator.
    sectors = {
        inputs = { border = "none", separator = true },
        toggles = { border = "none", separator = true },
        results = { border = "none" },
    },
    min_chars = 2,
    debounce = 200,
    max_results = 2000,
    max_columns = 512,
    flags = {
        case = "smart",
        whole_word = false,
        regex = false, -- literal by default (safer for a find & replace); toggle for regex power
        multiline = false,
        hidden = false,
        no_ignore = false,
    },
    exclude = { ".git" },
    confirm_apply = 1, -- always confirm before writing to disk (a replace is destructive)
    marker = "➤",
    persist = true,
    save = nil,
    max_history = 50,
    -- The cursor is hidden in every sector, so the actions live under <localleader> (fire from any sector),
    -- plus the direct sector keys: <CR> edits an input / flips a toggle / jumps to a match, <Tab> marks a
    -- result, and h/l pick a toggle or a mark-bar button. Configure <localleader> for the actions to work.
    keys = {
        goto_match = "<CR>",
        mark = "<Tab>",
        mark_all = "<localleader>a",
        unmark_all = "<localleader>A",
        apply = "<localleader>r",
        undo = "<localleader>u",
        quickfix = "<C-q>", -- send the results (marked, or all) to the quickfix list — a footer button too

        toggle_case = "<localleader>c",
        toggle_word = "<localleader>w",
        toggle_regex = "<localleader>x",
        toggle_hidden = "<localleader>h",
        history = "<localleader>H",
        save_search = "<localleader>S",
        help = "g?", -- the canonical lvim help chord (same everywhere), not a <localleader> key
        close = "<localleader>q",
    },
    hl = {},
}
