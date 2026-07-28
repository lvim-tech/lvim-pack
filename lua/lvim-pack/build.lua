-- lvim-pack.build: a plugin's build hook — running it, marking it done, and healing it later.
--
-- A build is ASYNCHRONOUS by default because a native-library compile can take a minute, and a
-- synchronous one freezes the whole UI (and the installer's panel, mid-redraw). On success the
-- plugin's directory is stamped with the marker file, holding the commit the build ran for — so a
-- build is not repeated until the plugin actually changes, and a FAILED build leaves no stamp and
-- is retried by the sweep.
--
---@module "lvim-pack.build"

local config = require("lvim-pack.config")
local state = require("lvim-pack.state")

local M = {}

--- The installed git commit of a plugin (HEAD), or nil for a non-git / `dir=` plugin.
---@param dir string
---@return string|nil
function M.plugin_commit(dir)
    local out = vim.fn.system({ "git", "-C", dir, "rev-parse", "HEAD" })
    return (vim.v.shell_error == 0) and (vim.trim(out)) or nil
end

--- Run a plugin's build hook.
---
--- The hook contract is GENERIC — this runner hardcodes no plugin, and each plugin declares its
--- own build in its spec:
---   • `"shell cmd"`   — run detached via `vim.system` (async).
---   • `":ExCommand"`  — run via `vim.cmd`.
---   • `function()`    — a SYNChronous build: runs to completion in the call.
---   • `function(done)`— an ASYNChronous build: it receives a `done(ok, err?)` callback and MUST
---                       call it when finished (e.g. a task's `:map`/`:catch` completion).
---@param name string
---@param build function|string
---@param dir? string
---@param on_done? fun(ok: boolean, err: string|nil)
---@return nil
function M.run(name, build, dir, on_done)
    -- Make the plugin loadable first: a require()-based build hook (e.g. a completion engine's
    -- `require("…").build()`) runs right after install, before the plugin is on the rtp. packadd
    -- is idempotent, so this is safe on the sweep path too.
    pcall(vim.cmd.packadd, name)

    -- Completion (always on the main loop, so it is safe from a `vim.system` / task callback):
    -- stamp the marker ONLY on success (a failed/partial build stays un-marked so the sweep
    -- retries), warn on failure, then forward to the caller.
    local function finish(ok, err)
        vim.schedule(function()
            if ok and dir then
                local c = M.plugin_commit(dir)
                if c then
                    pcall(vim.fn.writefile, { c }, dir .. "/" .. config.build_marker)
                end
            elseif not ok then
                vim.notify("lvim-pack: build failed for " .. name .. ": " .. tostring(err), vim.log.levels.WARN)
            end
            if on_done then
                on_done(ok, err)
            end
        end)
    end

    if type(build) == "function" then
        -- A hook that declares a parameter opts into the ASYNC contract (it calls `finish`
        -- itself); a zero-arg hook is SYNC (runs to completion in the call).
        local async = debug.getinfo(build, "u").nparams >= 1
        if async then
            local ok, err = pcall(build, finish)
            if not ok then
                finish(false, err) -- the hook threw before it could arrange completion
            end
        else
            local ok, err = pcall(build)
            finish(ok, err)
        end
    elseif type(build) == "string" then
        if build:sub(1, 1) == ":" then
            local ok, err = pcall(vim.cmd, build:sub(2))
            finish(ok, err)
        else
            -- Shell build, DETACHED (async) in the plugin dir so relative hooks like
            -- "./install --bin" resolve — the UI stays live while it runs.
            vim.system(
                { "sh", "-c", build },
                { cwd = dir, text = true },
                vim.schedule_wrap(function(res)
                    local ok = res.code == 0
                    finish(ok, ok and nil or (res.stderr ~= "" and res.stderr or ("exit " .. tostring(res.code))))
                end)
            )
        end
    elseif on_done then
        on_done(true)
    end
end

--- Self-healing builds: for every plugin with a build hook, run it when the recorded marker is
--- missing or stale (the commit changed). Covers a build added to an already installed plugin, a
--- reinstall (git checkout, no PackChanged), or a missing artefact. Deferred so it never blocks
--- startup; native libs land for the next session.
---@return nil
function M.ensure()
    local opt_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
    for name, m in pairs(state.meta) do
        if m.spec.build and not m.spec.dir then
            local dir = opt_dir .. name
            if vim.fn.isdirectory(dir) == 1 then
                local cur = M.plugin_commit(dir)
                local marker = dir .. "/" .. config.build_marker
                local built = (vim.fn.filereadable(marker) == 1) and vim.trim((vim.fn.readfile(marker)[1] or "")) or nil
                -- Rebuild when the marker is missing/stale (commit changed) OR when an optional
                -- `built` predicate reports the artefact is absent. The predicate self-heals a
                -- build that wrote its marker but produced no usable artefact (e.g. a native lib
                -- named per git SHA — a stale/failed build leaves the wrong file while the marker
                -- still looks current, so a marker-only check never recovers).
                local stale = cur and built ~= cur
                local missing_artefact = false
                if not stale and type(m.spec.built) == "function" then
                    local ok, present = pcall(m.spec.built, { dir = dir, commit = cur })
                    missing_artefact = ok and present == false
                end
                if stale or missing_artefact then
                    M.run(name, m.spec.build, dir)
                end
            end
        end
    end
end

return M
