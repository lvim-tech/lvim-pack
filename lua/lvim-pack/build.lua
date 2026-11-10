-- lvim-pack.build: a plugin's build hook — running it, marking it done, and healing it later.
--
-- A build is ASYNCHRONOUS by default because a native-library compile can take a minute, and a
-- synchronous one freezes the whole UI (and the installer's panel, mid-redraw). On success a
-- marker file is stamped in the loader's own state dir, holding the commit the build ran for — so
-- a build is not repeated until the plugin actually changes, and a FAILED build leaves no stamp
-- and is retried by the sweep.
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

--- Where a plugin's build marker lives: the loader's OWN state dir, not the plugin's directory.
--- Stamping the plugin's checkout left an untracked file in every clone with a build hook — each
--- user's `git status` permanently dirty over loader state. The marker belongs to the loader.
---@param name string
---@return string
local function marker_path(name)
    return vim.fn.stdpath("data") .. "/lvim-pack/built/" .. name
end

--- The CARGO_TARGET_DIR a shell build of `name` gets (`config.build_cache`), or nil when it is left to the
--- build: `"plugin"`, or a CARGO_TARGET_DIR the user already exported.
---@param name string
---@return string|nil
function M.target_dir(name)
    if vim.env.CARGO_TARGET_DIR and vim.env.CARGO_TARGET_DIR ~= "" then
        return nil
    end
    local where = config.build_cache or "cache"
    local base
    if where == "plugin" then
        return nil
    elseif where == "tmp" then
        base = vim.fs.joinpath(vim.env.TMPDIR or "/tmp", "lvim-pack-build")
    elseif where == "cache" then
        base = vim.fs.joinpath(vim.fn.stdpath("cache"), "lvim-pack", "build")
    elseif type(where) == "string" and where:sub(1, 1) == "/" then
        base = where
    else
        return nil
    end
    return vim.fs.joinpath(base, name)
end

--- Where a build that failed for want of a TOOL is remembered: `<commit>\t<tool>`.
---@param name string
---@return string
local function missing_path(name)
    return vim.fn.stdpath("data") .. "/lvim-pack/built/" .. name .. ".missing"
end

--- The tool a shell build could not find, from its exit status 127 and the shell's own message
--- (`sh: line 17: cargo: command not found`, `cargo: not found`), or nil.
---@param code integer
---@param stderr string|nil
---@return string|nil
function M.missing_tool(code, stderr)
    if code ~= 127 then
        return nil
    end
    local text = stderr or ""
    return text:match("([%w%._%+%-]+): command not found") or text:match("([%w%._%+%-]+): not found")
end

--- Whether the sweep should leave this build alone: it failed at this very commit because a tool was
--- missing, and that tool is still missing. Retrying then fails the same way on every start — on a server
--- with no compiler that was a warning per start, forever. A new commit, or the tool appearing on PATH,
--- clears it.
---@param name string
---@param commit string|nil
---@return boolean
function M.blocked(name, commit)
    local file = missing_path(name)
    if commit == nil or vim.fn.filereadable(file) == 0 then
        return false
    end
    local line = vim.fn.readfile(file, "", 1)[1] or ""
    local at, tool = line:match("^(%x+)\t(%S+)$")
    return at == commit and tool ~= nil and vim.fn.executable(tool) == 0
end

--- The installed git commit of a plugin (HEAD) — or, for a copy without `.git`, the commit recorded in its
--- `.lvim-pack-source` stamp — or nil.
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
    -- `readfile` RAISES on a missing file (E484), so each file is checked before it is read.
    if vim.fn.filereadable(dir .. "/.git/HEAD") == 0 then
        -- A copy WITHOUT `.git`: a checkout mirrored to a server by `lvim-pack.remote` carries the
        -- commit it was copied from in this stamp, so the marker check works there as it does here.
        local stamp_file = dir .. "/.lvim-pack-source"
        if vim.fn.filereadable(stamp_file) == 0 then
            return nil
        end
        local stamp = vim.trim(vim.fn.readfile(stamp_file, "", 1)[1] or "")
        return stamp:match("^%x+$") and stamp or nil
    end
    local head = vim.fn.readfile(dir .. "/.git/HEAD", "", 1)[1]
    if head == nil or head == "" then
        return nil
    end
    head = vim.trim(head)
    local ref = head:match("^ref:%s*(.+)$")
    if ref == nil then
        return head:match("^%x+$") and head or nil
    end
    if vim.fn.filereadable(dir .. "/.git/" .. ref) == 1 then
        local direct = vim.fn.readfile(dir .. "/.git/" .. ref, "", 1)[1]
        if direct ~= nil and direct ~= "" then
            return vim.trim(direct)
        end
    end
    -- The ref was packed: `packed-refs` holds `<sha> <refname>` lines.
    if vim.fn.filereadable(dir .. "/.git/packed-refs") == 0 then
        return nil
    end
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
                    local path = marker_path(name)
                    pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
                    pcall(vim.fn.writefile, { c }, path)
                    -- The retired in-repo stamp, if a previous version left one.
                    pcall(vim.fn.delete, dir .. "/" .. config.build_marker)
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
            -- The compile cache goes where `config.build_cache` says (see `M.target_dir`), not into the
            -- plugin; a build script reads it as `${CARGO_TARGET_DIR:-target}`.
            local target = M.target_dir(name)
            vim.system(
                { "sh", "-c", build },
                { cwd = dir, text = true, env = target and { CARGO_TARGET_DIR = target } or nil },
                vim.schedule_wrap(function(res)
                    -- `ok and nil or …` CANNOT express this: `true and nil` is nil, which is falsy,
                    -- so the `or` branch won every time and a SUCCESSFUL build reported its stderr
                    -- as an error (visible in the trace as `ok=true err=Compiling lvim-fuzzy…`).
                    -- cargo writes its progress to stderr, so "stderr is not empty" is not failure.
                    if res.code == 0 then
                        pcall(vim.fn.delete, missing_path(name))
                        finish(true)
                    else
                        -- A missing tool is remembered for this commit, so the sweep does not retry a build
                        -- that cannot succeed (see `M.blocked`). Any other failure is retried as before.
                        local tool = M.missing_tool(res.code, res.stderr)
                        local c = tool and dir and M.plugin_commit(dir)
                        if c then
                            pcall(vim.fn.mkdir, vim.fn.fnamemodify(missing_path(name), ":h"), "p")
                            pcall(vim.fn.writefile, { c .. "\t" .. tool }, missing_path(name))
                        end
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
---
--- `dir=` (dev) checkouts are swept too, not only opt-installed plugins: a dev checkout is still a
--- git repo, so the same commit-stamped marker self-heals it — a dev plugin's native library builds
--- once with no manual `sh native/build.sh`. Only an UNCOMMITTED native edit is missed (the commit
--- is unchanged); the `built` predicate, or a manual build, covers that case.
---@return nil
function M.ensure()
    local opt_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
    for name, m in pairs(state.meta) do
        if m.spec.build then
            local dir = m.spec.dir or (opt_dir .. name)
            if vim.fn.isdirectory(dir) == 1 then
                local cur = M.plugin_commit(dir)
                local marker = marker_path(name)
                -- Migrate a marker a previous version stamped in the plugin's directory: adopt
                -- its commit (no pointless rebuild) and remove the file from the repo.
                local legacy = dir .. "/" .. config.build_marker
                if vim.fn.filereadable(marker) == 0 and vim.fn.filereadable(legacy) == 1 then
                    local c = vim.trim((vim.fn.readfile(legacy)[1] or ""))
                    if c ~= "" then
                        pcall(vim.fn.mkdir, vim.fn.fnamemodify(marker, ":h"), "p")
                        pcall(vim.fn.writefile, { c }, marker)
                    end
                    pcall(vim.fn.delete, legacy)
                end
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
                if (stale or missing_artefact) and not M.blocked(name, cur) then
                    M.run(name, m.spec.build, dir)
                end
            end
        end
    end
end

return M
