-- lvim-pack: the vim.pack-based plugin loader for the lvim-tech set.
--
-- It owns LOADING only. What it installs is registered with lvim-pkg (the data hub) and painted by
-- lvim-installer (the panel) — both through soft hooks, both optional: the loader must still load
-- plugins on a machine where neither is present.
--
-- The host's `init.lua` clones this one repo and calls `setup{ spec = … }`; everything else —
-- bootstrapping the plugins the install itself needs, putting dev checkouts on the runtimepath,
-- expanding dependencies, pinning versions, loading eagerly by priority, wiring ft/cmd/keys/event
-- triggers, running build hooks — happens here.
--
-- THE ORDER IN `M.load` IS THE WHOLE DESIGN, and every step of it was learned from a failure:
--   1. builtins off, spec read
--   2. bootstrap clone + packadd — with plain `git`, because the first `vim.pack.add` reconciles
--      the entire lockfile and would install everything behind its own progress bar
--   3. `dir=` dev checkouts onto the runtimepath — BEFORE anything requires them
--   4. umbrella bundle, then dependency resolve, then pins
--   5. registry out to the data hub
--   6. the install UI — the first and only `vim.pack.add` of the session
--   7. eager loads by priority, then the lazy triggers
--   8. UIEnter freezes the startup stat and fires `User VeryLazy`; the build sweep follows
--
---@module "lvim-pack"

local bootstrap = require("lvim-pack.bootstrap")
local build = require("lvim-pack.build")
local config = require("lvim-pack.config")
local deps = require("lvim-pack.deps")
local load = require("lvim-pack.load")
local rtp = require("lvim-pack.rtp")
local state = require("lvim-pack.state")

local M = {}

--- Trace one phase, when tracing is on. Optional cross-plugin dependency: the loader must run on
--- a machine where the data hub is absent, so a missing tracer is simply silence.
---@param fmt string
---@param ... any
---@return nil
local function trace(fmt, ...)
    local ok, t = pcall(require, "lvim-pkg.trace")
    if ok then
        t.log(fmt, ...)
    end
end

--- Merge user options into the live config. Uses lvim-utils' shared merge when it is around and a
--- plain assign otherwise — this plugin has NO hard dependency on anything, because it is what
--- puts the others on the runtimepath.
---@param opts LvimPackConfig
---@return nil
local function merge(opts)
    local ok, utils = pcall(require, "lvim-utils.utils")
    if ok and type(utils.merge) == "function" then
        utils.merge(config, opts)
        return
    end
    for k, v in pairs(opts) do
        config[k] = v
    end
end

--- The spec table, from whichever form the host supplied.
---@return table<string, table|false>
local function spec_table()
    local s = config.spec
    if type(s) == "function" then
        local ok, res = pcall(s)
        return (ok and type(res) == "table") and res or {}
    end
    return type(s) == "table" and s or {}
end

--- Report the whole static registry to the data hub, once, after resolve.
---
--- `vim.pack.get()` is very slow (~800 ms — it reads git state per plugin), so the path, version
--- and source are reported from the specs instead of letting the hub query vim.pack for them.
---@return nil
local function register()
    local opt_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
    local registry = {}
    for name, m in pairs(state.meta) do
        local s = m.spec
        registry[name] = {
            repo = m.repo,
            dir = s.dir,
            path = s.dir or (opt_dir .. name),
            src = config.github .. m.repo,
            version = s.commit or s.version or s.branch,
            branch = s.branch,
            lazy = m.lazy,
            event = s.event,
            ft = s.ft,
            cmd = s.cmd,
            keys = s.keys,
            dependencies = s.dependencies,
            priority = s.priority,
            dependency = s.dependency,
            dep_of = s.dep_of,
        }
    end
    if config.on_register then
        pcall(config.on_register, registry)
    end
end

--- Make the lockfile follow the active pins: a plugin that tracks latest (no pin → version nil)
--- must not stay frozen at a stale locked revision on a fresh install. The lock entry for such a
--- plugin that is not yet on disk is dropped, so vim.pack resolves the branch tip instead of the
--- old recorded commit.
---@param pack_specs table[]
---@return nil
local function unlock_unpinned(pack_specs)
    local opt_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
    local lock_path = vim.fn.stdpath("config") .. "/nvim-pack-lock.json"
    local ok_read, content = pcall(vim.fn.readfile, lock_path)
    if not (ok_read and content and #content > 0) then
        return
    end
    local ok_dec, lock = pcall(vim.json.decode, table.concat(content, "\n"))
    if not (ok_dec and type(lock) == "table" and type(lock.plugins) == "table") then
        return
    end
    local changed = false
    for _, ps in ipairs(pack_specs) do
        if ps.version == nil and lock.plugins[ps.name] and vim.fn.isdirectory(opt_dir .. ps.name) == 0 then
            lock.plugins[ps.name] = nil
            changed = true
        end
    end
    if changed then
        pcall(vim.fn.writefile, { vim.json.encode(lock) }, lock_path)
    end
end

--- Time from the host's process start to a usable editor, frozen at UIEnter — the same point
--- every other manager measures to, before any VeryLazy work.
---
--- ASKED EARLIER, IT STILL ANSWERS. A dashboard paints before UIEnter and asks then; returning nil
--- there sent it to its own fallback, which measures elapsed time at the moment of asking — and on
--- a redraw seconds later that reads as a 14-second startup. Before the freeze this returns the
--- live elapsed time, which is the honest answer to "how long has starting taken so far".
---@return { startup_ms: number|nil }
function M.stats()
    if state.startup_ms == nil and config.start_time then
        return { startup_ms = (vim.uv.hrtime() - config.start_time) / 1e6 }
    end
    return { startup_ms = state.startup_ms }
end

--- Register and load every plugin.
---@return nil
function M.load()
    for _, guard in ipairs(config.disabled_builtins) do
        vim.g[guard] = 1
    end

    trace("load: start")
    local modules = spec_table()
    trace("spec: %d entries", vim.tbl_count(modules))

    -- The plugins the install itself needs, before the first `vim.pack.add`. On a first run this
    -- puts a window on screen; it stays up, NARRATING each phase, until the installer's own panel
    -- takes the screen — otherwise the seconds between the clone and that panel pass with nothing
    -- to look at (measured on a first run: eight seconds of a stale "cloning …" line).
    local first_run = bootstrap.run(modules)
    trace("bootstrap: done (first_run=%s)", tostring(first_run))

    -- Every `dir=` (dev) plugin onto the runtimepath BEFORE the dependency resolver runs. The
    -- resolver used to live in another plugin, which could itself be declared as a dir dependency
    -- — so without this the require failed, pcall-swallowed, leaving dependency spec tables
    -- un-normalised and crashing the load. The resolver is internal now, but the hub and the
    -- installer are still reached by require at register/install time, so the prepend stays.
    -- Scans top-level specs AND their nested dependency spec tables.
    do
        local function prepend_dir(spec)
            if type(spec) == "table" and spec.dir then
                rtp.add_dir(spec.dir)
            end
        end
        for _, spec in pairs(modules) do
            prepend_dir(spec)
            if type(spec) == "table" and type(spec.dependencies) == "table" then
                for _, dep in ipairs(spec.dependencies) do
                    prepend_dir(dep)
                end
            end
        end
    end

    -- DISTRIBUTION expansion: pull in every plugin declared in a module's own `lua/<name>/pack.lua`
    -- (an umbrella), so installing the umbrella installs the whole set. These are INSTALL-only —
    -- each still loads on its own spec, and a plugin the user already declared stays authoritative.
    -- Runs BEFORE resolve so the bundled plugins take part in dependency resolution and pinning.
    if first_run then
        bootstrap.say({ "Preparing the package manager…", "resolving dependencies" })
    end
    modules = deps.bundle(modules)
    trace("bundle: %d entries", vim.tbl_count(modules))

    -- Expand declared dependencies into the module graph (vim.pack does NOT auto-install them).
    modules = deps.resolve(modules)
    trace("resolve: %d entries", vim.tbl_count(modules))

    -- Pin the dependencies just added: a top-level module already carries its own pin from its
    -- declaration; a dependency without one is pinned by NAME, or tracks HEAD when the host has
    -- no answer for it.
    for repo, spec in pairs(modules) do
        if type(spec) == "table" and spec.commit == nil and not spec.dir then
            local ok, ref = pcall(config.pin, repo:match("([^/]+)$"))
            spec.commit = ok and ref or nil
        end
    end

    ---@type table[]   vim.pack specs for git-hosted plugins
    local pack_specs = {}
    ---@type string[]  eagerly-loaded plugin names
    local eager = {}
    ---@type string[]  lazily-loaded plugin names
    local deferred = {}

    for repo, spec in pairs(modules) do
        if spec ~= false then
            local name = repo:match("([^/]+)$")
            state.meta[name] = { repo = repo, spec = spec, lazy = false }
            if spec.dir then
                rtp.add_dir(spec.dir)
            else
                pack_specs[#pack_specs + 1] = {
                    src = config.github .. repo,
                    name = name,
                    version = spec.commit or spec.version or spec.branch,
                    has_build = spec.build ~= nil,
                }
            end
            -- `cond` (boolean or function): a plugin whose condition is false is still installed
            -- and registered, but never loaded and gets no triggers. Lets a setting gate a plugin.
            local enabled = true
            if spec.cond ~= nil then
                if type(spec.cond) == "function" then
                    local ok, res = pcall(spec.cond)
                    enabled = (ok and res) and true or false
                else
                    enabled = spec.cond and true or false
                end
            end
            local has_trigger = spec.event or spec.ft or spec.cmd or spec.keys
            local is_lazy = spec.lazy == true or has_trigger
            if not enabled then
                -- Installed but disabled: out of both lists, so nothing loads it. Marked lazy so
                -- the installer shows it as not loaded.
                state.meta[name].lazy = true
            elseif is_lazy then
                -- A plugin marked `lazy = true` with no concrete trigger has no way to load itself
                -- (there is no require hook). If it carries config/opts/init that must run, fall
                -- back to VeryLazy so it loads just after startup; a pure library (no config)
                -- stays lazy and loads on demand via require.
                --
                -- `dir=` (dev) plugins take this branch too. They used to be exempt, which meant a
                -- spec's cmd/ft/keys silently did nothing on a dev checkout while working for
                -- everyone else — the same config behaving two ways depending on whether the
                -- plugin happened to be cloned locally. A dir plugin is already on the runtimepath,
                -- so `packadd` was never what lazy deferred for it; what defers is its
                -- config/opts, which is exactly what lazy means here.
                if not has_trigger and (spec.config or spec.opts or spec.init) then
                    spec.event = "VeryLazy"
                end
                state.meta[name].lazy = true
                deferred[#deferred + 1] = name
            else
                eager[#eager + 1] = name
            end
        end
    end

    if first_run then
        bootstrap.say({ "Preparing the package manager…", "registering " .. vim.tbl_count(state.meta) .. " plugins" })
    end
    trace("register: %d plugins", vim.tbl_count(state.meta))
    register()
    trace("register: done")

    -- While the installer's panel is running it OWNS the build phase (so it can show a per-plugin
    -- "building …" status). The PackChanged-driven build is suppressed for that window to avoid
    -- double builds; it still covers every later update.
    local building_via_installer = false

    vim.api.nvim_create_autocmd("PackChanged", {
        callback = function(ev)
            if building_via_installer then
                return
            end
            local data = ev.data
            -- Build on install AND update — a native library must be rebuilt when the plugin
            -- changes.
            if not (data and (data.kind == "install" or data.kind == "update")) then
                return
            end
            local m = data.spec and state.meta[data.spec.name]
            local hook = m and m.spec.build
            if hook then
                local opt_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
                build.run(data.spec.name, hook, opt_dir .. data.spec.name)
            end
        end,
    })

    -- Install everything (cloning as needed) WITHOUT auto-running plugin/ files; load order is
    -- decided below, not by vim.pack.
    if #pack_specs > 0 then
        local opt_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
        trace("install: %d specs to consider", #pack_specs)
        unlock_unpinned(pack_specs)

        building_via_installer = true
        local ok, err = false, nil
        if config.install_ui then
            -- THE WINDOW STAYS UNTIL THE PANEL IS ACTUALLY UP. Closing it at the handover left a
            -- bare `[No Name]` on screen for the seconds the panel needs to load and paint its
            -- first frame (measured: eight of them). The panel is a float and opens on top; this
            -- one is closed once the install returns.
            if first_run then
                bootstrap.say({ "Installing plugins…", "the installer is starting" })
            end
            ok, err = pcall(config.install_ui, pack_specs, {
                -- The panel tells us the moment it is on screen; the phase window steps aside
                -- exactly then, so neither a gap nor an overlap is possible.
                on_visible = bootstrap.done,
                -- Run a plugin's build hook and report ok/err, so the panel can show
                -- "building … ✓ / ✗".
                build_runner = function(name)
                    local m = state.meta[name]
                    if not (m and m.spec.build and not m.spec.dir) then
                        return true
                    end
                    return build.run(name, m.spec.build, opt_dir .. name)
                end,
            })
        end
        building_via_installer = false
        trace("install: returned (ok=%s)", tostring(ok))
        if not ok then
            -- A FAILED PANEL IS NOT A SILENT ONE. Falling back without a word is what hid a real
            -- error behind a working install: the plugins landed, the panel never appeared, and
            -- nothing said why. The fallback still runs — the install must happen — but the
            -- reason is reported.
            if err ~= nil then
                vim.schedule(function()
                    vim.notify("lvim-pack: the install panel failed — " .. tostring(err), vim.log.levels.WARN)
                end)
            end
            -- The plain add installs correctly but says nothing, so the phase window stays up to
            -- say it instead.
            if first_run then
                bootstrap.say({ "Installing plugins…", "this runs once" })
            end
            pcall(vim.pack.add, pack_specs, { load = false, confirm = false })
        end
        bootstrap.done()
    end

    bootstrap.done()

    -- Eager plugins, highest priority first — and NAME as the tiebreak. Without it the order of
    -- everything at the default priority came from `pairs`, which Lua does not order: the same
    -- config loaded in a different sequence on every start, so a plugin that requires another at
    -- config time succeeded or failed by luck (reported as three consecutive starts with three
    -- different errors). Ties are now resolved the same way every time.
    table.sort(eager, function(a, b)
        local pa, pb = state.meta[a].spec.priority or 50, state.meta[b].spec.priority or 50
        if pa ~= pb then
            return pa > pb
        end
        return a < b
    end)
    trace("eager: %d plugins", #eager)
    for _, name in ipairs(eager) do
        load.plugin(name)
    end
    trace("eager: done")

    -- Lazy plugins: register their triggers. Sorted for the same reason — a trigger's side effects
    -- (a command, a keymap) must be registered in a fixed order too.
    trace("triggers: %d plugins", #deferred)
    table.sort(deferred)
    for _, name in ipairs(deferred) do
        load.triggers(name, state.meta[name].spec)
    end

    -- `User VeryLazy` shortly after the UI is ready, so plugins with `event = "VeryLazy"` load
    -- just after startup — and the startup stat is frozen at that same moment.
    -- FROZEN AT WHICHEVER COMES FIRST. UIEnter is the point every manager measures to, but a
    -- headless run never fires it, and a dashboard can paint before it — so VimEnter is a floor.
    vim.api.nvim_create_autocmd({ "UIEnter", "VimEnter" }, {
        once = true,
        callback = function()
            trace("UIEnter")
            if config.start_time and state.startup_ms == nil then
                state.startup_ms = (vim.uv.hrtime() - config.start_time) / 1e6
            end
            vim.defer_fn(function()
                trace("VeryLazy: fire")
                vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
                trace("VeryLazy: done")
            end, config.very_lazy_delay)
        end,
    })

    -- Self-heal native builds without manual steps: run any build hook whose marker is missing or
    -- stale. Deferred off the hot path.
    trace("load: done")
    vim.defer_fn(function()
        trace("build sweep: start")
        build.ensure()
        trace("build sweep: done")
    end, config.ensure_builds_delay)
end

--- Merge the host's options into the live config, install the defaults that reach for the sibling
--- plugins, and load.
---@param opts LvimPackConfig
---@return nil
function M.setup(opts)
    merge(opts or {})

    -- THE DEFAULT HOOKS, installed only where the host left the seam empty. They are set here
    -- rather than in config.lua because each is a `require` of a sibling plugin, and config.lua
    -- must stay loadable before any of them exists.
    if config.on_register == nil then
        config.on_register = function(registry)
            require("lvim-pkg").register_plugins(registry)
        end
    end
    if config.on_load == nil then
        config.on_load = function(name, reason, ms)
            require("lvim-pkg").record_load(name, reason, ms)
        end
    end
    if config.install_ui == nil then
        config.install_ui = function(specs, ctx)
            require("lvim-installer.bootstrap").install(specs, ctx)
            return true
        end
    end

    M.load()
end

return M
