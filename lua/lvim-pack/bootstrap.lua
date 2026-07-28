-- lvim-pack.bootstrap: the few plugins the INSTALL ITSELF needs, fetched before anything else —
-- and the only thing on screen until the installer's panel takes over.
--
-- WHY PLAIN `git clone` AND NOT vim.pack. The first `vim.pack.add` of a session reconciles the
-- WHOLE lockfile: called before these plugins exist, it clones every plugin in the spec behind
-- vim.pack's own aggregate progress bar — bypassing the installer's per-plugin panel and its build
-- phase entirely. Fetching just these few directly keeps the first `vim.pack.add` for the
-- installer, so it drives (and shows) the real install.
--
-- WHY THE WINDOW OUTLIVES THE CLONE. Between the clone and the installer's first frame there is
-- real work — dependency resolution, pins, the registry, loading the installer itself — and on a
-- first start that is several seconds. Closing the window when the clone ended left the reader
-- staring at an empty screen with nothing to say what was happening (reported from a first-run
-- test). It stays up, and says which phase it is in, until the panel replaces it.
--
-- A `dir=` (dev) plugin is skipped: it is already on the runtimepath and has no clone to make.
--
---@module "lvim-pack.bootstrap"

local config = require("lvim-pack.config")

local M = {}

---@type { buf: integer, win: integer }|nil  the live phase window
local panel = nil

--- Paint (or repaint) the phase window. There is no UI library yet — it is one of the things being
--- cloned — and `echo` is unreliable this early in startup, but a window paints on `:redraw`,
--- which is why this is a window and not a message.
---@param lines string[]
---@return nil
function M.say(lines)
    local width = 58
    local body = { "" }
    for _, l in ipairs(lines) do
        body[#body + 1] = "   " .. l
    end
    body[#body + 1] = ""
    if panel and vim.api.nvim_buf_is_valid(panel.buf) then
        pcall(vim.api.nvim_buf_set_lines, panel.buf, 0, -1, false, body)
        if vim.api.nvim_win_is_valid(panel.win) then
            pcall(vim.api.nvim_win_set_height, panel.win, #body)
        end
        vim.cmd("redraw")
        return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
    local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
        relative = "editor",
        row = math.max(0, math.floor((vim.o.lines - #body - 1) / 2)),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = #body,
        style = "minimal",
        border = "rounded",
        focusable = false,
        noautocmd = true,
    })
    if ok then
        panel = { buf = buf, win = win }
    end
    vim.cmd("redraw")
end

--- Close the phase window, if one is open. Called the moment something else owns the screen.
---@return nil
function M.done()
    if panel then
        if vim.api.nvim_win_is_valid(panel.win) then
            pcall(vim.api.nvim_win_close, panel.win, true)
        end
        panel = nil
        vim.cmd("redraw")
    end
end

--- Clone whatever of `config.bootstrap` is missing, then `packadd` all of it.
---@param modules table<string, table|false>  the spec table (to honour `dir=` dev checkouts)
---@return boolean cloned  something was actually fetched — i.e. this is a first run
function M.run(modules)
    local opt = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
    local missing = {}
    for _, repo in ipairs(config.bootstrap) do
        local name = repo:match("([^/]+)$")
        local spec = modules[repo]
        if not (type(spec) == "table" and spec.dir) and vim.fn.isdirectory(opt .. name) == 0 then
            missing[#missing + 1] = { repo = repo, name = name }
        end
    end

    local cloned = #missing > 0
    if cloned then
        local names = {}
        for _, m in ipairs(missing) do
            names[#names + 1] = m.name
        end
        -- Painted BEFORE the blocking clone, so it stays on screen during it.
        M.say({ "Preparing the package manager…", "cloning " .. table.concat(names, ", ") })
        vim.fn.mkdir(opt, "p")
        for i, m in ipairs(missing) do
            M.say({
                "Preparing the package manager…",
                ("cloning %s  (%d/%d)"):format(m.name, i, #missing),
            })
            pcall(vim.fn.system, { "git", "clone", "--filter=blob:none", config.github .. m.repo, opt .. m.name })
        end
    end

    for _, repo in ipairs(config.bootstrap) do
        local name = repo:match("([^/]+)$")
        local spec = modules[repo]
        if not (type(spec) == "table" and spec.dir) then
            pcall(vim.cmd.packadd, name)
        end
    end
    return cloned
end

return M
