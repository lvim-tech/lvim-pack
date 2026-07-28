-- lvim-pack.deps: the dependency graph resolver.
--
-- It lives HERE, inside the loader, and not in the data hub it came from: the loader cannot work
-- without it, and a resolver reached across a plugin boundary could be missing at exactly the
-- moment it is needed — which is what used to happen, silently, when a dev checkout had not yet
-- been put on the runtimepath.
-- Expands the `dependencies` declared on plugin specs into the flat module map the
-- loader installs from: every dependency — recursively — becomes its own module entry
-- so vim.pack clones it (vim.pack does NOT auto-install dependencies), while load order
-- is preserved through the normalized `dependencies` name list.
--
-- A dependency may be a bare "owner/repo" string, or a spec table carrying its own
-- config/opts and version pin:
--     dependencies = {
--       "owner/repo",
--       { "owner/repo2", opts = {...}, config = fn, commit = "abc123" },
--     }
-- Its config/opts run when it loads (deps load before their parent), and any pin
-- (commit/version/branch) is kept. A dependency can also be pinned by name through the
-- snapshot, exactly like a top-level plugin (applied by the loader, not here).
--
-- Plugins that exist ONLY as a dependency are tagged `dependency = true` + `dep_of` so
-- the installer can mark them in the browser; plugins also declared at top level keep
-- their own (authoritative) spec and are never tagged.
--
---@module "lvim-pack.deps"

local M = {}

--- Load a module's OWN distribution manifest (`lua/<name>/pack.lua`) from its plugin directory, if present.
--- A dir= (dev) plugin is read from its checkout; an installed plugin from the package opt dir. Returns the
--- table it exports, or nil (no manifest / unreadable / not on disk yet — e.g. first install before clone).
---@param repo string   "owner/repo"
---@param spec table     its module spec (may carry `dir`)
---@return table|nil
local function read_pack_manifest(repo, spec)
    local name = repo:match("([^/]+)$")
    if not name then
        return nil
    end
    local base = spec.dir or (vim.fn.stdpath("data") .. "/site/pack/core/opt/" .. name)
    local file = base .. "/lua/" .. name .. "/pack.lua"
    if vim.fn.filereadable(file) ~= 1 then
        return nil
    end
    local ok, manifest = pcall(dofile, file)
    return (ok and type(manifest) == "table") and manifest or nil
end

--- DISTRIBUTION expansion: for every module that ships its own `pack.lua` (an umbrella like lvim-nvim), ensure
--- each plugin it lists is registered so the package manager installs it — WITHOUT making it a load-order
--- dependency (so each still loads on its own spec / lazy triggers). A plugin the user ALREADY declared (top
--- level, with its own config/opts) is left untouched — the user's spec is authoritative; this only FILLS IN
--- the ones they did not declare. Mutates and returns `modules`. Call BEFORE `M.resolve`.
---@param modules table<string, table|false>
---@return table<string, table|false>
function M.bundle(modules)
    -- Snapshot the roots first; the loop inserts new (install-only) entries as it goes.
    local roots = {}
    for repo, spec in pairs(modules) do
        if type(spec) == "table" then
            roots[#roots + 1] = repo
        end
    end
    for _, repo in ipairs(roots) do
        local manifest = read_pack_manifest(repo, modules[repo])
        local deps = manifest and manifest.dependencies
        if type(deps) == "table" then
            for _, dep in ipairs(deps) do
                local drepo = type(dep) == "string" and dep or (type(dep) == "table" and dep[1] or nil)
                if drepo and modules[drepo] == nil then
                    -- Install-only: register it so vim.pack clones it. NOT added to any `dependencies` list,
                    -- so it loads on its own (lazy) spec — its config is the user's to add.
                    modules[drepo] = { bundled = true, bundled_by = repo }
                end
            end
        end
    end
    return modules
end

--- Normalize one dependency entry to (repo, spec-without-the-repo).
---@param dep string|table
---@return string|nil repo, table spec
local function normalize(dep)
    if type(dep) == "string" then
        return dep, {}
    end
    if type(dep) == "table" and type(dep[1]) == "string" then
        local spec = {}
        for k, v in pairs(dep) do
            if k ~= 1 then
                spec[k] = v
            end
        end
        return dep[1], spec
    end
    return nil, {}
end

--- Expand every spec's `dependencies` into top-level module entries (recursively).
--- Mutates and returns `modules` (repo → spec). Cycle-safe.
---@param modules table<string, table|false>
---@return table<string, table|false>
function M.resolve(modules)
    local seen = {}

    local function visit(repo, spec)
        if seen[repo] or type(spec) ~= "table" then
            return
        end
        seen[repo] = true
        local deps = spec.dependencies
        if type(deps) ~= "table" or #deps == 0 then
            return
        end
        -- Normalize spec.dependencies to a flat list of repo strings, so the loader's
        -- existing `dep:match("([^/]+)$")` load-order walk keeps working.
        local names = {}
        for _, dep in ipairs(deps) do
            local drepo, dspec = normalize(dep)
            if drepo then
                names[#names + 1] = drepo
                if not modules[drepo] then
                    -- Pulled in only as a dependency: register it so vim.pack installs it.
                    dspec.dependency = true
                    dspec.dep_of = repo
                    modules[drepo] = dspec
                end
                visit(drepo, modules[drepo]) -- recurse (its own deps); seen-guarded
            end
        end
        spec.dependencies = names
    end

    -- Snapshot the original keys first; visit() inserts new ones as it goes.
    local roots = {}
    for repo, spec in pairs(modules) do
        if type(spec) == "table" then
            roots[#roots + 1] = repo
        end
    end
    for _, repo in ipairs(roots) do
        visit(repo, modules[repo])
    end
    return modules
end

return M
