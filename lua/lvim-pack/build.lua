-- lvim-pack.build: a plugin's build hook — running it, marking it done, and healing it later.
--
-- A build is ASYNCHRONOUS by default because a native-library compile can take a minute, and a
-- synchronous one freezes the whole UI (and the installer's panel, mid-redraw). On success the
-- plugin's directory is stamped with the marker file, holding the commit the build ran for — so a
-- build is not repeated until the plugin actually changes, and a FAILED build leaves no stamp and
-- is retried by the sweep.
--
-- BECAUSE THE ANSWER COMES LATE, THE CALLER GETS IT THROUGH `on_done` — `run` returns the moment
-- the build has STARTED, so its return value says nothing about the result. Every caller that
-- reports a build (the installer's panel) must wait for that callback.
--
---@module "lvim-pack.build"

local config = require("lvim-pack.config")
local state = require("lvim-pack.state")

local M = {}

--- Builds currently in flight, by plugin name → the callbacks waiting on them.
---@type table<string, (fun(ok: boolean, err: string|nil))[]>
local running = {}

--- The installed git commit of a plugin (HEAD), or nil for a non-git / `dir=` plugin.
---
--- READ, NOT SPAWNED. This used to shell out to `git rev-parse HEAD`, which is a process per
--- plugin on the MAIN LOOP — and the build sweep calls it for every plugin that has a build hook,
--- right while the install panel is animating. On a first install that is dozens of blocking
--- spawns in a row and the editor stops answering (reported: the panel froze mid-count). The same
--- answer is two file reads: `.git/HEAD` is either the sha itself (a detached checkout) or a
--- `ref:` pointing at a file that holds it, with `packed-refs` as the fallback for a ref that has
--- been packed away.
---@param dir string
---@return string|nil
function M.plugin_commit(dir)
    local head = vim.fn.readfile(dir .. "/.git/HEAD", "", 1)[1]
    if head == nil or head == "" then
        return nil
    end
    head = vim.trim(head)
    local ref = head:match("^ref:%s*(.+)$")
    if ref == nil then
        return head:match("^%x+$") and head or nil
    end
    local direct = vim.fn.readfile(dir .. "/.git/" .. ref, "", 1)[1]
    if direct ~= nil and direct ~= "" then
        return vim.trim(direct)
    end
    -- The ref was packed: `packed-refs` holds `<sha> <refname>` lines.
    for _, line in ipairs(vim.fn.readfile(dir .. "/.git/packed-refs")) do
        local sha, name = line:match("^(%x+)%s+(%S+)$")
        if name == ref then
            return sha
        end
    end
    return nil
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
---
--- RETURNS NOTHING. Only `on_done` carries the result, and for a shell hook it arrives when the
--- process exits — a minute later for a native library. A caller reading the return value is
--- reading "the build started".
---@param name string
---@param build function|string
---@param dir? string
---@param on_done? fun(ok: boolean, err: string|nil)
---@return nil
function M.run(name, build, dir, on_done)
    -- ONE BUILD PER PLUGIN AT A TIME. The same plugin is asked to build from three independent
    -- places — the installer's build phase, the `PackChanged` hook, and the self-healing sweep —
    -- and the marker that would tell a later caller it is already done is written only when the
    -- build ENDS. So a request arriving while one is in flight used to start a SECOND compile over
    -- the same source tree into the same target dir. It attaches to the running build instead and
    -- is answered by it.
    if running[name] then
        if on_done then
            table.insert(running[name], on_done)
        end
        return
    end
    running[name] = {}

    -- Make the plugin loadable first: a require()-based build hook (e.g. a completion engine's
    -- `require("…").build()`) runs right after install, before the plugin is on the rtp. packadd
    -- is idempotent, so this is safe on the sweep path too.
    pcall(vim.cmd.packadd, name)

    -- Completion (always on the main loop, so it is safe from a `vim.system` / task callback):
    -- stamp the marker ONLY on success (a failed/partial build stays un-marked so the sweep
    -- retries), warn on failure, then answer the caller and everyone who attached meanwhile.
    local function finish(ok, err)
        vim.schedule(function()
            local waiting = running[name] or {}
            running[name] = nil
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
            -- A waiter's own error must not swallow the rest of them (nor the build's result).
            for _, cb in ipairs(waiting) do
                pcall(cb, ok, err)
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
            local ok, err = pcall(function()
                vim.cmd(build:sub(2))
            end)
            finish(ok, err)
        else
            -- Shell build, DETACHED (async) in the plugin dir so relative hooks like
            -- "./install --bin" resolve — the UI stays live while it runs.
            vim.system(
                { "sh", "-c", build },
                { cwd = dir, text = true },
                vim.schedule_wrap(function(res)
                    -- `ok and nil or …` CANNOT express this: `true and nil` is nil, which is falsy,
                    -- so the `or` branch won every time and a SUCCESSFUL build reported its stderr
                    -- as an error (visible in the trace as `ok=true err=Compiling lvim-fuzzy…`).
                    -- cargo writes its progress to stderr, so "stderr is not empty" is not failure.
                    if res.code == 0 then
                        finish(true)
                    else
                        finish(false, (res.stderr ~= "" and res.stderr) or ("exit " .. tostring(res.code)))
                    end
                end)
            )
        end
    else
        -- Not a runnable hook (a wrong type): nothing to run, nothing to stamp — but the slot must
        -- be released, or the plugin could never be built again this session.
        running[name] = nil
        if on_done then
            on_done(true)
        end
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
