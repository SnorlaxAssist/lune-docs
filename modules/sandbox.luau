local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local processArgs = table.clone(process.args)
local filePath: string = table.remove(processArgs, 1)
	or error("usage: lune run sandbox [SCRIPT_PATH] -- [ARGS]")

local DEFAULT_PRINT = print
local SANDBOXED_ENV = {
	debugName = filePath,
	environment = {
		require = nil,
		getfenv = nil,
		setfenv = nil,
		print = nil,
		warn = nil,
	},
}

local function discoverAndReadScript(filePath: string): string
	local scriptContents: string

	if fs.isFile(filePath) then
		scriptContents = fs.readFile(filePath)
		return scriptContents
	end

	if fs.isDir(filePath) then
		if fs.isFile(filePath .. "/init.luau") then
			scriptContents = fs.readFile(filePath .. "/init.luau")
		end

		if fs.isFile(filePath .. "/init.lua") then
			scriptContents = fs.readFile(filePath .. "init.lua")
		end
	end

	if scriptContents == nil then
		for _, ext in { ".luau", ".lua" } do
			local filePathExt = filePath .. ext
			if fs.isFile(filePathExt) then
				scriptContents = fs.readFile(filePathExt)
			end
		end

		if scriptContents == nil then
			error(`No such file or directory \`{filePath}\``)
		end
	end

	return scriptContents
end

local function sandboxGetfenv(): {}
	if table.isfrozen(SANDBOXED_ENV.environment) then
		return SANDBOXED_ENV.environment
	end
	return table.freeze(SANDBOXED_ENV.environment)
end

local function sandboxSetfenv(env: {}): never
	error("cannot call setfenv from sandbox")
end

local function sandboxPrint(...: any)
	DEFAULT_PRINT(`---- Output from {SANDBOXED_ENV.debugName} ----`)
	DEFAULT_PRINT(...)
	DEFAULT_PRINT(`---------------------------------------`)
end

local FLAG_ALL_FUNCTIONS = {};

type Protection = {
	[string]: Protection | string | boolean | (() -> (string | boolean))
}

local function virtualizeModule(module : any, protectedFunctions : Protection, lib : string)
	local virtualTree = {}
	local virtualizedModule = setmetatable({}, {
		__index = function(self, key)
			local virtualValue = virtualTree[key]
			if (virtualValue) then
				return virtualValue
			end
			local value = module[key];
			local flag = protectedFunctions == FLAG_ALL_FUNCTIONS or protectedFunctions[key]
			if type(value) == "function" then
				return function(...)
					if (flag) then
						local allowExecution: boolean = stdio.prompt(
							"confirm",
							if type(flag) == "string" then
								flag
							elseif type(flag) == "function" then
								flag()
							else
								`allow {SANDBOXED_ENV.debugName} to access {lib}.{key}?`
						)
						assert(allowExecution, `{lib}.{key} is protected`)
					end
					return value(...)
				end
			elseif (type(value) == "table") then
				local virtualizedValue = virtualizeModule(
					value,
					if type(flag) == "table" then flag else protectedFunctions,
					`{lib}.{key}`
				)
				virtualTree[key] = virtualizedValue
				return virtualizedValue
			end

			return module[key]
		end,
		__newindex = function()
			error("bad")
		end,
		__metatable = "The metatable is locked"
	})
	return virtualizedModule
end

local function virtualizeLibrary(lib : string, protectedFunctions : Protection)
	local luneModule = require(`@lune/{lib}`)

	return virtualizeModule(luneModule, protectedFunctions, lib);
end

local SANDBOXED_LUNE_STD_LIB = {
	["@lune/fs"] = virtualizeLibrary("fs", FLAG_ALL_FUNCTIONS),
	["@lune/luau"] = virtualizeLibrary("luau", {
		load = true,
	}),
	["@lune/process"] = virtualizeLibrary("process", {
		spawn = true,
	}),
	["@lune/stdio"] = setmetatable({
		write = sandboxPrint,
		ewrite = sandboxPrint, -- TODO: do this
	}, {
		__index = virtualizeLibrary("stdio", FLAG_ALL_FUNCTIONS),
		__metatable = "The metatable is locked"
	}),
	["@lune/net"] = virtualizeLibrary("net", FLAG_ALL_FUNCTIONS),
	["@lune/roblox"] = virtualizeLibrary("roblox", {
		getAuthCookie = `allow {SANDBOXED_ENV.debugName} to access your .ROBLOSECURITY token?`,
	}),
	["@lune/serde"] = virtualizeLibrary("serde", {}),
	["@lune/task"] = virtualizeLibrary("task", {}),
	["@lune/regex"] = virtualizeLibrary("regex", {}),
	["@lune/datetime"] = virtualizeLibrary("datetime", {}),
}
local function sandboxedRequire(path: string)
	local module = SANDBOXED_LUNE_STD_LIB[path]

	if module then
		return module
	else
		local contents = discoverAndReadScript(path)

		local evalChunk = luau.load(contents, SANDBOXED_ENV)
		return evalChunk()
	end
end

SANDBOXED_ENV.environment.require = sandboxedRequire
SANDBOXED_ENV.environment.getfenv = sandboxGetfenv
SANDBOXED_ENV.environment.setfenv = sandboxSetfenv
SANDBOXED_ENV.environment.print = sandboxPrint
SANDBOXED_ENV.environment.warn = sandboxPrint
luau.load(discoverAndReadScript(filePath), table.freeze(SANDBOXED_ENV))()
