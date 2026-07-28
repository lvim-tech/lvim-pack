-- lvim-pack.load: loading one plugin, and the triggers that decide when.
--
-- Loading and triggering live together because they share the same two tables (`state.loaded`,
-- `state.meta`) and because a trigger's whole body is a call to the loader — splitting them would
-- buy a file and cost a cycle.
--
-- ORDER MATTERS INSIDE A LOAD: `init` runs BEFORE the plugin is sourced (that is the entire reason
-- it is separate from `config` — a plugin configured through global variables reads them while its
-- own files are being sourced, so anything set afterwards is simply too late), then `packadd`,
-- then `config`/`opts`.
--
---@module "lvim-pack.load"

local config = require("lvim-pack.config")
local state = require("lvim-pack.state")

local M = {}

--- Resolve a plugin's main module for opts-based setup (the lazy-style heuristic).
---@param name string
---@return table|nil
local function main_module(name)
    local candidates = {
        name,
        (name:gsub("%.nvim$", "")),
        (name:gsub("^nvim%-", "")),
        (name:gsub("%-nvim$", "")),
        (name:gsub("%.lua$", "")),
    }
    for _, candidate in ipairs(candidates) do
        local ok, mod = pcall(require, candidate)
        if ok and type(mod) == "table" and type(mod.setup) == "function" then
            return mod
        end
    end
    return nil
end

--- Run a plugin's config/opts once it is on the runtimepath. `init` is NOT run here — it runs
--- before the plugin is sourced, in `M.plugin`.
---@param repo string
---@param spec table
---@return nil
local function run_config(repo, spec)
    if type(spec.config) == "function" then
        pcall(spec.config)
    elseif spec.opts ~= nil then
        local opts = type(spec.opts) == "function" and spec.opts() or spec.opts
        local mod = main_module(repo:match("([^/]+)$"))
        if mod then
            pcall(mod.setup, opts)
        end
    end
end

--- Load a plugin and its declared dependencies.
---@param name string
---@param reason? string  why/when it loaded (e.g. "eager", "event: VimEnter")
---@return nil
function M.plugin(name, reason)
    if state.loaded[name] then
        return
    end
    state.loaded[name] = true
    local m = state.meta[name]
    if not m then
        return
    end
    -- Dependencies first — each timed in its own call, so the report attributes the cost where it
    -- was actually spent.
    for _, dep in ipairs(m.spec.dependencies or {}) do
        M.plugin(dep:match("([^/]+)$"), "required by " .. name)
    end
    local t0 = vim.uv.hrtime()
    if type(m.spec.init) == "function" then
        pcall(m.spec.init)
    end
    if not m.spec.dir then
        pcall(vim.cmd.packadd, name)
    end
    run_config(m.repo, m.spec)
    if config.on_load then
        pcall(config.on_load, name, reason or "eager", (vim.uv.hrtime() - t0) / 1e6)
    end
end

--- Register the lazy-loading triggers declared on a plugin spec.
---@param name string
---@param spec table
---@return nil
function M.triggers(name, spec)
    local function load(reason)
        M.plugin(name, reason)
    end

    if spec.ft then
        local fts = type(spec.ft) == "table" and spec.ft or { spec.ft }
        vim.api.nvim_create_autocmd("FileType", {
            pattern = fts,
            once = true,
            callback = function(args)
                load("ft: " .. (args.match or vim.bo.filetype))
                -- Re-fire FileType so the just-loaded plugin sees the current buffer.
                vim.api.nvim_exec_autocmds("FileType", { pattern = vim.bo.filetype })
            end,
        })
    end

    if spec.event then
        local events = type(spec.event) == "table" and spec.event or { spec.event }
        for _, entry in ipairs(events) do
            local evt, pat = entry:match("^(%S+)%s+(.+)$")
            evt = evt or entry
            -- The "VeryLazy" pseudo-event → the `User VeryLazy` this loader fires once the UI is
            -- ready (see the orchestrator in init.lua).
            if evt == "VeryLazy" then
                evt, pat = "User", "VeryLazy"
            end
            vim.api.nvim_create_autocmd(evt, {
                pattern = pat,
                once = true,
                callback = function()
                    load("event: " .. entry)
                end,
            })
        end
    end

    if spec.cmd then
        local cmds = type(spec.cmd) == "table" and spec.cmd or { spec.cmd }
        for _, cmd in ipairs(cmds) do
            vim.api.nvim_create_user_command(cmd, function(args)
                pcall(vim.api.nvim_del_user_command, cmd)
                load("cmd: " .. cmd)
                vim.cmd(string.format("%s%s %s", args.bang and "!" or "", cmd, args.args or ""))
            end, { nargs = "*", range = true, bang = true })
        end
    end

    if spec.keys then
        -- `keys` may be a list of specs, a single lhs string, or a function returning a list —
        -- evaluate the function once to get the specs.
        local raw = type(spec.keys) == "function" and spec.keys() or spec.keys
        local keys = type(raw) == "table" and raw or { raw }
        for _, key in ipairs(keys) do
            -- A key spec is lhs (string) or { lhs, rhs?, mode?, desc? }. The rhs is the ACTION, and
            -- it must be installed after loading — otherwise the re-fed key only loads the plugin
            -- and does nothing.
            local lhs, rhs, mode, desc
            if type(key) == "table" then
                lhs, rhs, mode, desc = key[1], key[2], key.mode, key.desc
            else
                lhs = key
            end
            mode = mode or { "n", "v" }
            if type(lhs) == "string" then
                vim.keymap.set(mode, lhs, function()
                    pcall(vim.keymap.del, mode, lhs)
                    load("keys: " .. lhs)
                    if rhs ~= nil then
                        vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
                    end
                    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "m", false)
                end, { desc = desc })
            end
        end
    end
end

return M
