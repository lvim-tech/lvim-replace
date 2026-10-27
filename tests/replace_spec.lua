-- The argv that is handed to ripgrep, and what applying a replacement is allowed to touch.
--
-- ripgrep is the single engine for both the search and the replace, so the argv IS the
-- semantics: a flag that does not reach it is a feature that silently does nothing. And apply
-- writes to the user's files, which makes its refusals more important than its successes --
-- above all the one that matters: a line that has changed since the search is skipped, never
-- spliced with offsets that no longer describe it.

local search = require("lvim-replace.search")
local apply = require("lvim-replace.apply")
local config = require("lvim-replace.config")

--- A panel state with every flag off, ready to be overridden per case.
---@param over? table
---@return table
local function state(over)
    local st = {
        search = "foo",
        replace = "bar",
        paths = "",
        flags_extra = "",
        scope_paths = {},
        flags = {
            case = "smart",
            whole_word = false,
            regex = true,
            multiline = false,
            hidden = false,
            no_ignore = false,
        },
    }
    return vim.tbl_deep_extend("force", st, over or {})
end

--- Is `flag` among the argv tokens?
---@param argv string[]
---@param flag string
---@return boolean
local function has(argv, flag)
    return vim.tbl_contains(argv, flag)
end

--- The tokens that follow each occurrence of `flag`.
---@param argv string[]
---@param flag string
---@return string[]
local function values_of(argv, flag)
    local out = {}
    for i, tok in ipairs(argv) do
        if tok == flag and argv[i + 1] then
            out[#out + 1] = argv[i + 1]
        end
    end
    return out
end

describe("lvim-replace: the argv ripgrep is given")

it("the two passes ask ripgrep for different things", function()
    local json = search.build_argv(state(), "json")
    eq("rg", json[1])
    eq(true, has(json, "--json"), "pass 1 wants the spans")
    eq(false, has(json, "--replace=bar"), "rg --json ignores --replace, which is why there are two passes")

    local repl = search.build_argv(state(), "replace")
    eq(true, has(repl, "--replace=bar"), "pass 2 wants ripgrep's OWN replacement text, capture groups expanded")
    eq(true, has(repl, "--only-matching"))
    eq(true, has(repl, "-H"), "a forced filename keeps the rows uniform for one file and for a tree")
    eq(false, has(repl, "--json"))
end)

it("every flag toggle reaches the argv", function()
    eq(true, has(search.build_argv(state(), "json"), "--smart-case"))
    eq(true, has(search.build_argv(state({ flags = { case = "ignore" } }), "json"), "--ignore-case"))
    eq(true, has(search.build_argv(state({ flags = { case = "sensitive" } }), "json"), "--case-sensitive"))
    eq(true, has(search.build_argv(state({ flags = { whole_word = true } }), "json"), "--word-regexp"))
    eq(true, has(search.build_argv(state({ flags = { hidden = true } }), "json"), "--hidden"))
    eq(true, has(search.build_argv(state({ flags = { no_ignore = true } }), "json"), "--no-ignore"))

    local ml = search.build_argv(state({ flags = { multiline = true } }), "json")
    eq(true, has(ml, "--multiline"))
    eq(true, has(ml, "--multiline-dotall"), "a multiline pattern without dotall would not cross a newline")
end)

it("regex OFF means a fixed string, not an escaped pattern", function()
    eq(false, has(search.build_argv(state(), "json"), "--fixed-strings"))
    eq(true, has(search.build_argv(state({ flags = { regex = false } }), "json"), "--fixed-strings"))
end)

it("the search term is positional, after the -- separator", function()
    local argv = search.build_argv(state({ search = "--not-a-flag" }), "json")
    local sep
    for i, tok in ipairs(argv) do
        if tok == "--" then
            sep = i
        end
    end
    truthy(sep, "without a separator a search term starting with - would be read as a flag")
    eq("--not-a-flag", argv[sep + 1])
end)

it("the scope is the cwd tree unless paths were given", function()
    local argv = search.build_argv(state(), "json")
    eq(".", argv[#argv])
    local scoped = search.build_argv(state({ scope_paths = { "/tmp/a", "/tmp/b" } }), "json")
    eq("/tmp/b", scoped[#scoped])
    eq("/tmp/a", scoped[#scoped - 1])
end)

it("a glob with a space stays ONE argv token", function()
    -- A plain whitespace split broke `-g 'my dir/*'` into two bogus tokens.
    local argv = search.build_argv(state({ paths = "*.lua 'my dir/*'" }), "json")
    local globs = values_of(argv, "-g")
    truthy(vim.tbl_contains(globs, "*.lua"), vim.inspect(globs))
    truthy(vim.tbl_contains(globs, "my dir/*"), "the quoted glob was split: " .. vim.inspect(globs))
end)

it("the free-form flags are honoured, quotes included", function()
    local argv = search.build_argv(state({ flags_extra = "--max-depth 3 -g '!vendor/*'" }), "json")
    eq(true, has(argv, "--max-depth"))
    eq(true, has(argv, "3"))
    truthy(vim.tbl_contains(values_of(argv, "-g"), "!vendor/*"))
end)

it("the configured excludes are passed as negated globs", function()
    local was = config.exclude
    config.exclude = { ".git", "node_modules" }
    local globs = values_of(search.build_argv(state(), "json"), "-g")
    config.exclude = was
    truthy(vim.tbl_contains(globs, "!.git"))
    truthy(vim.tbl_contains(globs, "!node_modules"))
end)

it("the per-line column cap applies to the pass that prints lines", function()
    local json = search.build_argv(state(), "json")
    eq(true, has(json, "--max-columns"), "a minified bundle's single megabyte line would be printed whole")
    eq(true, has(json, "--max-columns-preview"))
    eq(false, has(search.build_argv(state(), "replace"), "--max-columns"), "pass 2 prints only matches")
end)

describe("lvim-replace: applying a replacement")

--- A file on disk holding `lines`, in a directory of its own.
---@param lines string[]
---@param name? string
---@return string path
local function file_with(lines, name)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/" .. (name or "subject.txt")
    vim.fn.writefile(lines, path)
    return path
end

--- One entry, as the panel hands it over: the line as the SEARCH saw it, plus the spans.
--- A span's `s` is the 0-based start byte and `e` the end byte, exclusive.
---@param path string
---@param lnum integer
---@param text string
---@param spans table[]
---@return table
local function entry(path, lnum, text, spans)
    return { path = path, lnum = lnum, text = text, spans = spans }
end

it("a span is replaced in place, with ripgrep's own replacement text", function()
    local path = file_with({ "keep foo keep" })
    apply.reset()
    local res = apply.apply({ entry(path, 1, "keep foo keep", { { s = 5, e = 8, after = "bar" } }) }, "bar")
    eq(1, res.changed)
    eq(0, res.skipped)
    eq({ "keep bar keep" }, vim.fn.readfile(path))
end)

it("several spans on one line all land, in spite of their offsets moving", function()
    local path = file_with({ "foo and foo and foo" })
    apply.reset()
    local res = apply.apply({
        entry(path, 1, "foo and foo and foo", {
            { s = 0, e = 3, after = "X" },
            { s = 8, e = 11, after = "YY" },
            { s = 16, e = 19, after = "ZZZ" },
        }),
    }, "")
    eq(1, res.changed)
    eq({ "X and YY and ZZZ" }, vim.fn.readfile(path), "spliced right to left, so an earlier span keeps its offsets")
end)

it("a span with no replacement of its own uses the Replace value, and an empty one deletes", function()
    local path = file_with({ "keep foo keep" })
    apply.reset()
    apply.apply({ entry(path, 1, "keep foo keep", { { s = 5, e = 8 } }) }, "")
    eq({ "keep  keep" }, vim.fn.readfile(path), "an empty Replace is a delete")
end)

it("a line that changed since the search is skipped, not corrupted", function()
    local path = file_with({ "something else entirely" })
    apply.reset()
    local res = apply.apply({ entry(path, 1, "keep foo keep", { { s = 5, e = 8, after = "bar" } }) }, "bar")
    eq(0, res.changed)
    eq(1, res.skipped, "the offsets no longer describe this line")
    eq(0, res.files)
    eq({ "something else entirely" }, vim.fn.readfile(path), "the file is untouched")
end)

it("a line number past the end of the file is skipped", function()
    local path = file_with({ "one line" })
    apply.reset()
    local res = apply.apply({ entry(path, 99, "whatever", { { s = 0, e = 1, after = "x" } }) }, "x")
    eq(1, res.skipped)
    eq({ "one line" }, vim.fn.readfile(path))
end)

it("a file without a final newline does not gain one", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/nonewline.txt"
    local fd = assert(io.open(path, "wb"))
    fd:write("keep foo keep")
    fd:close()

    apply.reset()
    eq(1, apply.apply({ entry(path, 1, "keep foo keep", { { s = 5, e = 8, after = "bar" } }) }, "bar").changed)

    local raw = assert(io.open(path, "rb"))
    local content = raw:read("*a")
    raw:close()
    eq("keep bar keep", content, "a replacement may not add bytes nobody asked for")
end)

it("a CRLF file keeps its line terminator", function()
    local path = file_with({ "keep foo keep" })
    -- Rewrite with CRLF endings, which is what readfile hands back with a trailing \r per line.
    local fd = assert(io.open(path, "wb"))
    fd:write("keep foo keep\r\n")
    fd:close()

    apply.reset()
    local res = apply.apply({ entry(path, 1, "keep foo keep", { { s = 5, e = 8, after = "bar" } }) }, "bar")
    eq(1, res.changed, "the stored match text has no \\r, so the comparison has to tolerate one")

    local raw = assert(io.open(path, "rb"))
    local content = raw:read("*a")
    raw:close()
    eq("keep bar keep\r\n", content, "a replacement must not silently convert the file's endings")
end)

it("an untouched line of a CRLF file keeps its ending too", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/multi.txt"
    local fd = assert(io.open(path, "wb"))
    fd:write("first foo\r\nsecond line\r\nthird line\r\n")
    fd:close()

    apply.reset()
    eq(1, apply.apply({ entry(path, 1, "first foo", { { s = 6, e = 9, after = "bar" } }) }, "bar").changed)

    local raw = assert(io.open(path, "rb"))
    local content = raw:read("*a")
    raw:close()
    eq("first bar\r\nsecond line\r\nthird line\r\n", content, "changing one word rewrote every line ending in the file")
end)

it("undo restores every file of the batch, once", function()
    local a = file_with({ "foo one" }, "a.txt")
    local b = file_with({ "foo two" }, "b.txt")
    apply.reset()
    eq(false, apply.can_undo())

    local res = apply.apply({
        entry(a, 1, "foo one", { { s = 0, e = 3, after = "bar" } }),
        entry(b, 1, "foo two", { { s = 0, e = 3, after = "bar" } }),
    }, "bar")
    eq(2, res.changed)
    eq(2, res.files)
    eq(true, apply.can_undo())

    eq(2, apply.undo().files)
    eq({ "foo one" }, vim.fn.readfile(a))
    eq({ "foo two" }, vim.fn.readfile(b))
    eq(false, apply.can_undo(), "the batch is spent")
    eq(nil, apply.undo())
end)

it("the undo stack is last in, first out", function()
    local path = file_with({ "foo" })
    apply.reset()
    apply.apply({ entry(path, 1, "foo", { { s = 0, e = 3, after = "one" } }) }, "one")
    eq({ "one" }, vim.fn.readfile(path))
    apply.apply({ entry(path, 1, "one", { { s = 0, e = 3, after = "two" } }) }, "two")
    eq({ "two" }, vim.fn.readfile(path))

    apply.undo()
    eq({ "one" }, vim.fn.readfile(path), "the most recent batch comes back first")
    apply.undo()
    eq({ "foo" }, vim.fn.readfile(path))
end)

it("reset drops the history so a stale batch cannot linger", function()
    local path = file_with({ "foo" })
    apply.reset()
    apply.apply({ entry(path, 1, "foo", { { s = 0, e = 3, after = "bar" } }) }, "bar")
    eq(true, apply.can_undo())
    apply.reset()
    eq(false, apply.can_undo())
    eq({ "bar" }, vim.fn.readfile(path), "resetting forgets the undo, it does not revert the change")
end)

it("a loaded buffer is authoritative, even when its path holds pattern characters", function()
    -- bufnr() treats its argument as a PATTERN, so a path containing [ or * could miss the real
    -- buffer -- and then the change would be written to disk under the buffer's unsaved edits,
    -- which the next :w would revert. The lookup has to be an exact normalized-name match.
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/odd[1]name.txt"
    vim.fn.writefile({ "on disk foo" }, path)

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved foo" })

    apply.reset()
    local res = apply.apply({ entry(path, 1, "unsaved foo", { { s = 8, e = 11, after = "bar" } }) }, "bar")
    eq(1, res.changed, "the buffer's own line is what the search saw")
    eq({ "unsaved bar" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "the change lands in the buffer")

    apply.undo()
    eq({ "unsaved foo" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.cmd("bwipeout!")
end)
