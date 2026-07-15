-- lvim-replace.highlights: the self-theming highlight factory.
-- Every group the panel paints is derived from the LIVE lvim-utils palette here, and registered
-- through `lvim-utils.highlight.bind` so it re-applies on ColorScheme / palette sync (and stays
-- overridable off-lvim). Nothing in the UI code inlines a colour — it references one of these
-- NAMED groups. Tints follow the set's canon: `mtint(accent, t)` = blend the accent toward the
-- popup bg (higher t = more accent), the fold/help-window tint scale.
--
---@module "lvim-replace.highlights"

local hl = require("lvim-utils.highlight")

local M = {}

--- Build every LvimReplace* group from the live palette. Passed to `hl.bind`, so it is re-run on
--- every palette change; read the palette INSIDE the factory so the groups track the theme.
---@param c table  the live lvim-utils palette
---@return table<string, table>
function M.build(c)
    local bg = c.bg_dark
    local mtint = function(accent, t)
        return hl.blend(accent, bg, t)
    end
    return {
        -- File header row: a blue block with the path in bright blue + a dimmer match count.
        LvimReplaceFileRow = { bg = mtint(c.blue, 0.14) },
        LvimReplaceFilePath = { fg = c.blue, bold = true, bg = mtint(c.blue, 0.14) },
        LvimReplaceFileCount = { fg = c.fg_dark, bg = mtint(c.blue, 0.14) },
        -- Match rows: alternating faint blue / yellow stripes (the help-window striping canon). The ACTIVE
        -- row (the hidden cursor's line) reads on top of these as a stronger accent bar (LvimReplaceActiveRow).
        LvimReplaceRowOdd = { bg = mtint(c.blue, 0.05) },
        LvimReplaceRowEven = { bg = mtint(c.yellow, 0.05) },
        -- The ACTIVE row bar — the layered panel hides the cursor, so the row it sits on is painted with this
        -- strong accent bg (the picker/help-window active-row canon). Used in the toggles + results layers; the
        -- input layer deepens its own field accent instead (the `*Sel` groups below).
        LvimReplaceActiveRow = { bg = mtint(c.blue, 0.26), bold = true },
        -- The line:col location prefix, dimmed so the code reads first.
        LvimReplaceLineNr = { fg = c.green },
        LvimReplaceColNr = { fg = c.cyan },
        -- The matched span inside the line (before replacement): warm, struck-through when a replace is set.
        LvimReplaceMatch = { fg = c.orange, bold = true },
        LvimReplaceMatchDel = { fg = c.red, strikethrough = true },
        -- The replacement span (after): green, so a diff reads del(red) → add(green).
        LvimReplaceReplace = { fg = c.green, bold = true },
        -- DIFF view (a Replace value is set): the match renders as two rows — the ORIGINAL on a faint red wash
        -- (deletion) and the REPLACEMENT below it on a faint green wash (addition), each with a gutter sign.
        LvimReplaceDiffDel = { bg = mtint(c.red, 0.08) },
        LvimReplaceDiffAdd = { bg = mtint(c.green, 0.08) },
        LvimReplaceDiffDelSign = { fg = c.red, bold = true },
        LvimReplaceDiffAddSign = { fg = c.green, bold = true },
        -- The replacement text on the AFTER row: the untouched context dimmed, so the green insert stands out.
        LvimReplaceReplaceContext = { fg = c.fg_dark },
        -- The multi-select marker in the front column (above every row tint).
        LvimReplaceMarker = { fg = c.magenta, bold = true },
        -- The devicon default (per-ft colours come from the icon provider's own groups).
        LvimReplaceIcon = { fg = c.blue },
        -- The four input fields, each in its OWN accent (the тинт canon): the ROW is that accent tinted
        -- toward the bg with the accent as the fg (so the typed text reads in the field's colour), and the
        -- label BADGE is a stronger tint of the same accent, bold. Four distinct accents so the fields read
        -- as four different colours: Search = blue, Replace = green, Files = yellow, Flags = cyan.
        -- Each field's full-row group carries BOTH the tinted bg AND the accent fg (hl_eol), so the whole row
        -- — the value text included — reads in the field's colour; the label BADGE overrides its own columns
        -- with a stronger tint. The `*Sel` group is the ACTIVE-row variant: the same accent, a deeper bg + bold,
        -- so the selected input field glows in its own colour (never a foreign bar).
        LvimReplaceFieldSearch = { bg = mtint(c.blue, 0.10), fg = c.blue },
        LvimReplaceFieldSearchBadge = { bg = mtint(c.blue, 0.28), fg = c.blue, bold = true },
        LvimReplaceFieldSearchSel = { bg = mtint(c.blue, 0.26), fg = c.blue, bold = true },
        LvimReplaceFieldReplace = { bg = mtint(c.green, 0.10), fg = c.green },
        LvimReplaceFieldReplaceBadge = { bg = mtint(c.green, 0.28), fg = c.green, bold = true },
        LvimReplaceFieldReplaceSel = { bg = mtint(c.green, 0.26), fg = c.green, bold = true },
        LvimReplaceFieldFiles = { bg = mtint(c.yellow, 0.10), fg = c.yellow },
        LvimReplaceFieldFilesBadge = { bg = mtint(c.yellow, 0.28), fg = c.yellow, bold = true },
        LvimReplaceFieldFilesSel = { bg = mtint(c.yellow, 0.26), fg = c.yellow, bold = true },
        LvimReplaceFieldFlags = { bg = mtint(c.cyan, 0.10), fg = c.cyan },
        LvimReplaceFieldFlagsBadge = { bg = mtint(c.cyan, 0.28), fg = c.cyan, bold = true },
        LvimReplaceFieldFlagsSel = { bg = mtint(c.cyan, 0.26), fg = c.cyan, bold = true },
        -- The toggles layer (Case / Whole word / Regex / Hidden) — a faint neutral row bg with the label in fg
        -- and the state coloured (on = green, off = dim, the case value = cyan). Mark-all / Unmark-all are the
        -- two ACTION rows in the same layer, in magenta.
        LvimReplaceToggleRow = { bg = mtint(c.blue, 0.06) },
        LvimReplaceToggleLabel = { fg = c.fg },
        LvimReplaceToggleOn = { fg = c.green, bold = true },
        LvimReplaceToggleOff = { fg = c.fg_dark },
        LvimReplaceToggleValue = { fg = c.cyan, bold = true },
        -- The Mark all / Unmark all BAR wears the BOTTOM footer bar's look: a yellow-tint row with the button
        -- labels in yellow (footer-label accent) and the bracketed `[M]` / `[U]` hotkeys in blue (footer-key
        -- accent). The bar is a non-interactive header (the cursor never lands on it).
        LvimReplaceActionRow = { bg = mtint(c.yellow, 0.12) },
        LvimReplaceAction = { fg = c.yellow, bold = true },
        LvimReplaceActionKey = { fg = c.blue, bold = true },
        -- The live "marked / total" counter — the pickers' result-count box: GREEN fg on a green tint badge.
        LvimReplaceCount = { fg = c.green, bg = mtint(c.green, 0.28), bold = true },
        -- The panel window's Normal background (the docked sidebar bg, like the outline).
        LvimReplaceNormal = { bg = c.bg_dark, fg = c.fg },
        -- The empty / status message inside the results region.
        LvimReplaceEmpty = { fg = c.fg_dark, italic = true },
        LvimReplaceError = { fg = c.red },
    }
end

return M
