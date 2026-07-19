# lvim-replace

Project-wide **find & replace** for Neovim, powered by [ripgrep](https://github.com/BurntSushi/ripgrep)
and built entirely on the lvim-tech ecosystem (the `lvim-ui` surface chassis, the `lvim-utils` palette /
icons / SQLite store).

Search the whole project with the full power of `rg`, see every match grouped by file, watch a live **diff**
of the replacement as you type — and, uniquely, **mark exactly which results to change** and apply only
those. ripgrep is the single engine for both search and replace, so a regex written once behaves
identically in the results and in the applied change.

## Features

- **Three navigable sectors, one docked split.** The panel opens as a docked vertical split (never a
  centred float), a stack of three sectors — **Inputs** (Search / Replace / Files / Flags), **Toggles**
  (Case / Whole word / Regex / Hidden), **Results** (a Mark bar + the matches). `<C-j>` / `<C-k>` step
  between the sectors and the footer; `<C-h>` / `<C-l>` jump out to the editor beside the panel and back to
  the sector you left.
- **Inline-editable Inputs.** The four fields are a real editable buffer — type straight into them, `<CR>` /
  `<Tab>` move between fields. The hardware cursor shows only while typing; every other sector hides it and
  paints the active row instead.
- **Live ripgrep search** — streamed off the main thread, debounced as you type; results grouped by file
  with a devicon header, `line:col`, and the matched span highlighted.
- **Diff preview.** The preview is live from the first Search character. A **Replace value** renders each
  match as a two-row **diff**: the original on a faint red wash (matched span red + struck through) and the
  replacement below it on a faint green wash with a `+` gutter (ripgrep's own replacement, capture groups
  `$1` expanded). An **empty Replace** renders a single row with the match struck through (a "will be
  deleted" indicator — an empty Replace is a valid delete). What you see is exactly what apply writes.
- **Selective apply via marking** — mark/unmark the result under the cursor (or a file header to mark all
  its matches), with **mark all / unmark all** and a live `marked / total` counter on the Mark bar. Apply
  writes **only the marked matches** (marking is required — to change everything, mark all first). A
  changed-since-search line is skipped, never corrupted.
- **Undo** — every applied batch snapshots the affected files; one key reverts the whole batch (through the
  buffer when the file is open, so its own undo history stays intact).
- **Navigate** — jump from a result to its file / line / column in the editor window.
- **Toggles** — case (smart / ignore / sensitive), whole-word, regex ↔ literal, hidden files — a single
  centered row of buttons (`h` / `l` to pick, `<CR>` / `<Space>` to flip), plus a free-form **Flags** field
  for any other `rg` argument.
- **Scopes** — whole project, the current file, the word under the cursor, or the visual selection.
- **History & named searches** — recent searches are remembered and named searches can be saved, persisted
  in a per-plugin SQLite database (own file under `stdpath("data")/lvim-replace`, never a central DB).
- **Quickfix export** — send the marked results (or all) to the quickfix list.
- **Configurable chrome** — a border and separator per sector (`config.sectors`).
- Self-themes from the active palette; `:checkhealth lvim-replace`.

## Requirements

- Neovim >= 0.10
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) >= 14 recommended
- `lvim-utils` and `lvim-ui` (part of the lvim-tech set)
- `sqlite.lua` — optional, only for history / named searches (search & replace work without it)

## Installation

Install with the lvim-tech **lvim-installer**, or with Neovim's native `vim.pack`:

```lua
vim.pack.add({ "https://github.com/lvim-tech/lvim-replace" })
require("lvim-replace").setup()
```

## Usage

`:LvimReplace [subcommand]`

| Subcommand  | Action                                         |
| ----------- | ---------------------------------------------- |
| `open`      | Open the panel (default)                       |
| `toggle`    | Toggle the panel                               |
| `close`     | Close the panel                                |
| `file`      | Open limited to the current file               |
| `word`      | Open with the word under the cursor pre-filled |
| `selection` | Open with the visual selection pre-filled      |

The Lua API mirrors the subcommands: `require("lvim-replace").open()` / `.toggle()` / `.close()` /
`.open_current_file()` / `.open_cword()` / `.open_visual()`.

### Keys (inside the panel)

The **footer** actions fire from every sector — the plain keys shown on the buttons, plus their
`<localleader>` aliases. `m` / `n` (mark all / unmark all) also fire from any sector; the sector-specific
keys act in their own sector. Only `q` closes the panel — `<Esc>` just leaves insert in the Inputs.

| Key               | Where     | Action                                            |
| ----------------- | --------- | ------------------------------------------------- |
| `<C-j>` / `<C-k>` | any       | Next / previous sector (and the footer)           |
| `<C-h>` / `<C-l>` | any       | Jump out to the editor beside the panel, and back |
| `<CR>` / `<Tab>`  | Inputs    | Next field (`<S-Tab>` previous)                   |
| `h` / `l`         | Toggles   | Pick a flag — `<CR>` / `<Space>` flips it         |
| `<CR>`            | Results   | Jump to the match under the cursor                |
| `<Tab>`           | Results   | Mark / unmark the match, then advance             |
| `m` / `n`         | any       | Mark all / unmark all                             |
| `r`               | any       | Replace the marked matches                        |
| `u`               | any       | Undo the last applied batch                       |
| `<C-q>`           | any       | Send the results (marked, or all) to quickfix     |
| `g?`              | any       | Keymap cheatsheet                                 |
| `q`               | any       | Close the panel                                   |

The toggles, history and save-search actions also keep their `<localleader>` keys (see the config below).

## Default configuration

`setup()` merges your options into the live config. The full default config, every option at its default:

```lua
require("lvim-replace").setup({
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
    min_chars = 2, -- minimum Search characters before ripgrep runs
    debounce = 200, -- milliseconds a field change is debounced before searching
    max_results = 2000, -- cap on matching LINES shown (ripgrep is stopped past it)
    max_columns = 512, -- ripgrep --max-columns (0 disables the per-line length cap)
    flags = {
        case = "smart", -- "smart" | "ignore" | "sensitive"
        whole_word = false, -- rg --word-regexp
        regex = false, -- false = literal (--fixed-strings); true = regex
        multiline = false, -- rg --multiline --multiline-dotall (matches that SPAN lines preview but are not appliable — apply splices one line)
        hidden = false, -- rg --hidden
        no_ignore = false, -- rg --no-ignore
    },
    exclude = { ".git" }, -- globs always excluded (rg -g '!<glob>')
    confirm_apply = 1, -- apply of >= this many matches asks to confirm first (1 = always)
    marker = "➤", -- the mark glyph in the results' front column
    persist = true, -- persist history + named searches (SQLite)
    save = nil, -- store DIRECTORY (nil = stdpath("data")/lvim-replace)
    max_history = 50, -- how many recent searches to keep
    -- The cursor is hidden outside the Inputs, so the footer actions have plain keys (r / u / <C-q> / g? / q)
    -- that fire frame-wide; the toggles / history / save keep their <localleader> keys.
    keys = {
        goto_match = "<CR>",
        mark = "<Tab>",
        mark_all = "<localleader>a",
        unmark_all = "<localleader>A",
        apply = "<localleader>r",
        undo = "<localleader>u",
        quickfix = "<C-q>",
        toggle_case = "<localleader>c",
        toggle_word = "<localleader>w",
        toggle_regex = "<localleader>x",
        toggle_hidden = "<localleader>h",
        history = "<localleader>H",
        save_search = "<localleader>S",
        help = "g?",
        close = "<localleader>q",
    },
    hl = {}, -- highlight-group name overrides
})
```

## How search & replace work

ripgrep is the single engine for both. A search runs two passes:

1. `rg --json` — the authoritative matches: file, line, the line text, and every submatch's byte span.
   This drives the results, the match highlight, marking and navigation. Streamed off the main thread
   and parsed incrementally, so a broad search never blocks typing.
2. `rg --only-matching --column --replace=<replace>` (only when a Replace VALUE is set) — ripgrep's own
   replacement text per match, zipped onto pass 1's spans by `(file, line, column)`. `rg --json` ignores
   `--replace`, which is exactly why the replacement needs its own pass. This drives the two-row diff; an
   empty Replace needs no second pass (the match is just struck through as a deletion indicator).

Applying splices each marked line's spans with their replacement text (right-to-left so earlier spans keep
their offsets) and writes only the touched files — never a whole-file `rg --replace`, so only the marked
matches change.

## License

BSD-3-Clause. See `LICENSE`.
