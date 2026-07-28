-- lvim-pack.health: `:checkhealth lvim-pack`.
--
-- The checks are the ones that explain an actual symptom. A loader that ran but registered nothing
-- looks identical to a healthy one until a plugin is missing; a `spec` that is not a table means
-- the host wired the bootstrap wrong; a second copy of this plugin on the runtimepath means the
-- dev checkout and the installed clone are both live, and which one answered `require` is a coin
-- toss. None of that is visible without asking.
--
---@module "lvim-pack.health"

local config = require("lvim-pack.config")
local state = require("lvim-pack.state")

local health = vim.health

local M = {}

--- Run the checks.
---@return nil
function M.check()
    health.start("lvim-pack")

    -- 0.12, not 0.11: `vim.pack` is what this loader is built on, and 0.11 does not have it.
    -- `has()` rather than `vim.version.ge`, because a nightly calls itself `0.13.0-dev` and semver
    -- sorts a pre-release BELOW its release, so a version compare would reject the very build this
    -- is developed on.
    if vim.fn.has("nvim-0.12") == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.error("Neovim 0.12 or newer is required (vim.pack)")
    end

    if vim.pack ~= nil then
        health.ok("vim.pack is available")
    else
        health.error("vim.pack is missing on this build — there is nothing for the loader to drive")
    end

    -- ── the host's wiring ────────────────────────────────────────────────────
    health.start("lvim-pack: setup")

    local spec = config.spec
    if spec == nil then
        health.error("`spec` is not set — setup() was never called, or was called without one", {
            'require("lvim-pack").setup({ spec = <table|function> })',
        })
    elseif type(spec) == "function" then
        local ok, res = pcall(spec)
        if ok and type(res) == "table" then
            health.ok(("spec: a function returning %d entries"):format(vim.tbl_count(res)))
        else
            health.error("`spec` is a function but it does not return a table")
        end
    elseif type(spec) == "table" then
        health.ok(("spec: a table of %d entries"):format(vim.tbl_count(spec)))
    else
        health.error("`spec` must be a table or a function returning one, got " .. type(spec))
    end

    if config.start_time then
        local s = require("lvim-pack").stats()
        if s.startup_ms then
            local when = state.startup_ms and " (frozen)" or " (still starting)"
            health.ok(("startup: %.0f ms%s"):format(s.startup_ms, when))
        else
            health.warn("startup: no measurement yet")
        end
    else
        health.info("`start_time` was not passed — `stats().startup_ms` stays nil")
    end

    -- ── what it actually loaded ─────────────────────────────────────────────
    health.start("lvim-pack: plugins")

    local total, loaded, waiting = 0, 0, 0
    for name, m in pairs(state.meta) do
        total = total + 1
        if state.loaded[name] then
            loaded = loaded + 1
        elseif m.lazy then
            -- Marked lazy AND not loaded — the two are not complements: an eager plugin is loaded
            -- and not lazy, and a lazily-loaded one is BOTH, so subtracting one from the other
            -- counted the eager ones backwards (it read "-25 waiting").
            waiting = waiting + 1
        end
    end
    if total == 0 then
        health.error("no plugins registered — the loader ran with an empty spec, or did not run at all")
    else
        health.ok(("%d plugins registered: %d loaded, %d waiting on a trigger"):format(total, loaded, waiting))
    end

    -- ── the seams ────────────────────────────────────────────────────────────
    health.start("lvim-pack: seams")

    for _, seam in ipairs({ "on_register", "on_load", "install_ui" }) do
        if type(config[seam]) == "function" then
            health.ok(seam .. ": wired")
        else
            health.info(seam .. ": not wired — the loader works, that side just hears nothing")
        end
    end

    if pcall(require, "lvim-pkg") then
        health.ok("lvim-pkg found — the registry and load times are recorded")
    else
        health.info("lvim-pkg absent — plugins load, but nothing records what happened")
    end
    if pcall(require, "lvim-installer.bootstrap") then
        health.ok("lvim-installer found — installs get the progress panel")
    else
        health.info("lvim-installer absent — installs fall back to a plain vim.pack.add")
    end

    -- ── one copy, not two ────────────────────────────────────────────────────
    local copies = vim.api.nvim_get_runtime_file("lua/lvim-pack/init.lua", true)
    if #copies <= 1 then
        health.ok("one copy on the runtimepath: " .. (copies[1] or "?"))
    else
        health.warn(("%d copies on the runtimepath — which one answers `require` is not obvious"):format(#copies), {
            "A dev checkout and an installed clone are both live.",
            table.concat(copies, "\n"),
        })
    end
end

return M
