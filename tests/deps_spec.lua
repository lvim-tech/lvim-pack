-- The dependency graph, expanded into what the package manager can install.
--
-- vim.pack does NOT install a plugin's dependencies, so every dependency -- recursively -- has to
-- become its own module entry, while the load ORDER is preserved by normalising each spec's
-- `dependencies` to a flat list of repo names. Two rules make that safe and are easy to get
-- wrong: a plugin the user ALSO declared at top level keeps its own authoritative spec and is
-- never tagged as somebody's dependency, and the walk is cycle-safe -- two plugins that depend on
-- each other must resolve rather than recurse forever.

local deps = require("lvim-pack.deps")

--- Resolve a module map and hand it back (it is mutated in place by design).
---@param modules table
---@return table
local function resolved(modules)
    return deps.resolve(modules)
end

describe("lvim-pack: expanding dependencies")

it("a bare dependency becomes its own module entry", function()
    local mods = resolved({ ["o/parent"] = { dependencies = { "o/child" } } })
    truthy(mods["o/child"], "vim.pack installs module entries, so a dependency has to be one")
    eq(true, mods["o/child"].dependency, "it exists only as a dependency, which the browser marks")
    eq("o/parent", mods["o/child"].dep_of)
end)

it("the parent's dependency list becomes flat repo names", function()
    local mods = resolved({
        ["o/parent"] = {
            dependencies = { "o/a", { "o/b", opts = { x = 1 } } },
        },
    })
    eq({ "o/a", "o/b" }, mods["o/parent"].dependencies, "in declaration order, which is the load order")
end)

it("a dependency declared as a table keeps its own config and pin", function()
    local cfg = function() end
    local mods = resolved({
        ["o/parent"] = {
            dependencies = { { "o/child", opts = { a = 1 }, config = cfg, commit = "abc123" } },
        },
    })
    local child = mods["o/child"]
    eq({ a = 1 }, child.opts)
    eq(cfg, child.config)
    eq("abc123", child.commit, "a pin on a dependency is still a pin")
    eq(nil, child[1], "the repo itself is the key, not a field of the spec")
end)

it("dependencies of dependencies are expanded too", function()
    local mods = resolved({
        ["o/top"] = { dependencies = { "o/mid" } },
        ["o/mid"] = { dependencies = { "o/leaf" } },
    })
    truthy(mods["o/leaf"], "the whole graph has to be installable, not just its first level")
    eq("o/mid", mods["o/leaf"].dep_of)
    eq({ "o/leaf" }, mods["o/mid"].dependencies)
end)

it("a dependency nobody declared is discovered through its parent's spec", function()
    local mods = resolved({ ["o/top"] = { dependencies = { { "o/mid", dependencies = { "o/deep" } } } } })
    truthy(mods["o/mid"])
    truthy(mods["o/deep"], "a dependency's own dependencies count, however it was declared")
end)

it("a plugin the user declared at top level keeps its own spec", function()
    local own_config = function() end
    local mods = resolved({
        ["o/parent"] = { dependencies = { { "o/child", opts = { from = "parent" } } } },
        ["o/child"] = { opts = { from = "user" }, config = own_config },
    })
    eq({ from = "user" }, mods["o/child"].opts, "the user's spec is authoritative")
    eq(own_config, mods["o/child"].config)
    eq(nil, mods["o/child"].dependency, "and it is not somebody's dependency; it is its own plugin")
    eq(nil, mods["o/child"].dep_of)
end)

it("two plugins that depend on each other resolve instead of recursing forever", function()
    local mods = resolved({
        ["o/a"] = { dependencies = { "o/b" } },
        ["o/b"] = { dependencies = { "o/a" } },
    })
    eq({ "o/b" }, mods["o/a"].dependencies)
    eq({ "o/a" }, mods["o/b"].dependencies)
end)

it("a plugin that depends on itself is not a loop either", function()
    local mods = resolved({ ["o/self"] = { dependencies = { "o/self" } } })
    eq({ "o/self" }, mods["o/self"].dependencies)
end)

it("a disabled module is left exactly as it is", function()
    local mods = resolved({ ["o/off"] = false, ["o/on"] = { dependencies = { "o/dep" } } })
    eq(false, mods["o/off"], "false means the user turned it off; it is not a spec to walk")
    truthy(mods["o/dep"])
end)

it("a spec with no dependencies is untouched", function()
    local mods = resolved({ ["o/alone"] = { opts = { a = 1 } } })
    eq({ opts = { a = 1 } }, mods["o/alone"])
    eq(1, vim.tbl_count(mods))
end)

it("a dependency entry that is neither a string nor a spec is ignored", function()
    local mods = resolved({ ["o/parent"] = { dependencies = { 42, {}, "o/real" } } })
    eq({ "o/real" }, mods["o/parent"].dependencies, "junk cannot become a module entry")
end)

describe("lvim-pack: bundling a distribution's plugins")

--- A plugin checkout on disk that ships its own `lua/<name>/pack.lua` manifest.
---@param repo string     "owner/name"
---@param manifest string the Lua source the manifest returns
---@return string dir
local function checkout_with_manifest(repo, manifest)
    local name = repo:match("([^/]+)$")
    local dir = vim.fn.tempname() .. "/" .. name
    vim.fn.mkdir(dir .. "/lua/" .. name, "p")
    vim.fn.writefile({ "return " .. manifest }, dir .. "/lua/" .. name .. "/pack.lua")
    return dir
end

it("a distribution's plugins are registered so they get installed", function()
    local dir = checkout_with_manifest("lvim-tech/lvim-nvim", '{ dependencies = { "o/one", "o/two" } }')
    local mods = deps.bundle({ ["lvim-tech/lvim-nvim"] = { dir = dir } })

    truthy(mods["o/one"], "the umbrella's list is what the package manager clones")
    eq(true, mods["o/one"].bundled)
    eq("lvim-tech/lvim-nvim", mods["o/one"].bundled_by)
    truthy(mods["o/two"])
end)

it("a bundled plugin is NOT made a load-order dependency", function()
    local dir = checkout_with_manifest("lvim-tech/lvim-nvim", '{ dependencies = { "o/one" } }')
    local mods = deps.bundle({ ["lvim-tech/lvim-nvim"] = { dir = dir } })
    eq(nil, mods["lvim-tech/lvim-nvim"].dependencies, "each bundled plugin loads on its own spec")
    eq(nil, mods["o/one"].dependency, "it is bundled, not depended upon")
end)

it("a plugin the user already declared is left untouched", function()
    local dir = checkout_with_manifest("lvim-tech/lvim-nvim", '{ dependencies = { "o/one" } }')
    local user_opts = { mine = true }
    local mods = deps.bundle({
        ["lvim-tech/lvim-nvim"] = { dir = dir },
        ["o/one"] = { opts = user_opts },
    })
    eq(user_opts, mods["o/one"].opts, "the user's spec is authoritative")
    eq(nil, mods["o/one"].bundled, "and it was not overwritten with an install-only stub")
end)

it("a manifest entry declared as a table is read by its repo", function()
    local dir = checkout_with_manifest("lvim-tech/lvim-nvim", '{ dependencies = { { "o/one", opts = {} } } }')
    local mods = deps.bundle({ ["lvim-tech/lvim-nvim"] = { dir = dir } })
    truthy(mods["o/one"], "a table entry names its repo in [1]")
end)

it("a checkout without a manifest bundles nothing", function()
    local dir = vim.fn.tempname() .. "/plain"
    vim.fn.mkdir(dir, "p")
    local mods = deps.bundle({ ["o/plain"] = { dir = dir } })
    eq(1, vim.tbl_count(mods), "no manifest, nothing to bundle")
end)

it("a manifest that does not load bundles nothing, rather than raising", function()
    local dir = checkout_with_manifest("o/broken", "{ this is not lua")
    local ok, mods = pcall(deps.bundle, { ["o/broken"] = { dir = dir } })
    truthy(ok, "a broken manifest in somebody's checkout must not stop the loader: " .. tostring(mods))
    eq(1, vim.tbl_count(mods))
end)

it("bundling and resolving compose, in that order", function()
    local dir = checkout_with_manifest("lvim-tech/lvim-nvim", '{ dependencies = { "o/bundled" } }')
    local mods = deps.resolve(deps.bundle({
        ["lvim-tech/lvim-nvim"] = { dir = dir },
        ["o/parent"] = { dependencies = { "o/child" } },
    }))
    truthy(mods["o/bundled"], "install-only, from the manifest")
    truthy(mods["o/child"], "a real dependency, from a spec")
    eq(true, mods["o/child"].dependency)
    eq(nil, mods["o/bundled"].dependency)
end)
