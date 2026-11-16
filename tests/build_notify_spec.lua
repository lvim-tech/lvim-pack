-- lvim-pack.build: a slow build says when it starts and when it is done.

local build = require("lvim-pack.build")
local config = require("lvim-pack.config")

--- Run a build and collect the messages it sends.
---@param name string
---@param hook string|function
---@param opts? table
---@return string[] messages, boolean? ok
local function run(name, hook, opts)
    local seen, result = {}, nil
    local notify = vim.notify
    vim.notify = function(msg)
        seen[#seen + 1] = msg
    end
    build.run(name, hook, nil, function(ok)
        result = ok
    end, opts)
    vim.wait(5000, function()
        return result ~= nil
    end, 10)
    vim.notify = notify
    return seen, result
end

describe("lvim-pack.build: messages")

it("a shell build says it started and that it is done", function()
    local seen, ok = run("notify-shell", "true")
    eq(true, ok)
    eq({ "lvim-pack: building notify-shell…", "lvim-pack: built notify-shell" }, seen)
end)

it("a failed build says only that it failed", function()
    local seen, ok = run("notify-fail", "exit 3")
    eq(false, ok)
    eq("lvim-pack: building notify-fail…", seen[1])
    truthy(seen[2] and seen[2]:find("build failed for notify-fail", 1, true), vim.inspect(seen))
    eq(2, #seen)
end)

it("quiet (the installer panel) and build_notify = false say nothing on success", function()
    eq({}, (run("notify-quiet", "true", { quiet = true })))
    config.build_notify = false
    local seen = run("notify-off", "true")
    config.build_notify = true
    eq({}, seen)
end)

it("a quick build (an Ex command, a sync function) says nothing", function()
    eq({}, (run("notify-ex", ":echo")))
    eq({}, (run("notify-sync", function() end)))
end)
