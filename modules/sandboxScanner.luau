local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local parser = require("parser")

local processArgs = table.clone(process.args)
local filePath: string = table.remove(processArgs, 1)
	or error("usage: lune run sandbox [SCRIPT_PATH] -- [ARGS]")

local DEFAULT_PRINT = print

local function createSandboxEnviroment(path : string)
	local enviroment =  {
		require = nil,
		getfenv = nil,
		setfenv = nil,
		print = nil,
		warn = nil,
	}
	enviroment.getfenv = function()
		return enviroment
	end
	return {
		debugName = path,
		environment = enviroment,
	}
end

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

local function sandboxSetfenv(env: {}): never
	error("cannot call setfenv from sandbox")
end

local function createSandboxPrint(sandbox, ...: any)
	return function(...)
		DEFAULT_PRINT(`---- Output from {sandbox.debugName} ----`)
		DEFAULT_PRINT(...)
		DEFAULT_PRINT(`---------------------------------------`)
	end
end

local function requestModules(sandbox, modulesInUse: {string})
	for i, v in modulesInUse do
		if sandbox.MODULES[v] then
			continue
		end
		local allowLib: boolean = stdio.prompt(
			"confirm",
			`allow {sandbox.debugName} to access [{v}]?`
		)
		if allowLib then
			sandbox.MODULES[v] = require(v)
		end
	end
end

local function isLuneModule(string : string)
	return string:match("^@lune/") ~= nil
end

local function clean(str : string)
	return str
		:gsub("^[%c%s]*", "")
		:gsub("[%c%s]*", "")
end

local function scanModuleSource(source: string , sourceName : string): {string}
	local nav = parser.navigator()
	nav:SetSource(source)
	local modulesInUse = {}
	local moduleSource : {string} = {}
	for token, src in nav.Next do
		table.insert(moduleSource, src)
		if token == "string" then
			local cleansrc = clean(src)
			
			if cleansrc == "`" then
				local closed = false
				local string_interpolation : {string} = {}
				for subtoken, subsrc in nav.Next do
					local subcleansrc = clean(subsrc)
					if subtoken == "string" and subcleansrc == "`" then
						closed = true
						break;
					end
					table.insert(string_interpolation, subsrc)
				end
				if not closed then
					local line = #table.concat(moduleSource):split("\n")
					error(`{sourceName}:{line}: incomplete string interpolation`)
				end
				cleansrc = table.concat(string_interpolation)
				table.move(string_interpolation, 1, #string_interpolation, #moduleSource + 1, moduleSource)
			end
			
			local stringContent = cleansrc
				:gsub("\"", "")
				:gsub("[%[%]=]", "")

			if isLuneModule(stringContent) then
				table.insert(modulesInUse, stringContent)
			end
		end
	end
	return modulesInUse
end

local function createSandboxedRequire(sandbox)
	return function(path: string)
		local module = sandbox.MODULES[path]
		
		if isLuneModule(path) then
			assert(module, `module [{path}] not found`)
		end

		if module then
			return module
		else
			local contents = discoverAndReadScript(path)

			local moduleSandbox = createSandboxEnviroment(path)
			moduleSandbox.MODULES = {}
			moduleSandbox.environment.require = createSandboxedRequire(moduleSandbox)
			moduleSandbox.environment.setfenv = sandboxSetfenv
			moduleSandbox.environment.print = createSandboxPrint(moduleSandbox)
			moduleSandbox.environment.warn = moduleSandbox.environment.print

			local modulesInUse = scanModuleSource(contents, path)

			requestModules(moduleSandbox, modulesInUse)

			table.freeze(moduleSandbox)

			return luau.load(contents, moduleSandbox)()
		end
	end
end

local rootSandbox = createSandboxEnviroment(filePath)
rootSandbox.MODULES = {}
rootSandbox.environment.require = createSandboxedRequire(rootSandbox)
rootSandbox.environment.setfenv = sandboxSetfenv
rootSandbox.environment.print = createSandboxPrint(rootSandbox)
rootSandbox.environment.warn = rootSandbox.environment.print

local scriptContent = discoverAndReadScript(filePath)
local modulesInUse = scanModuleSource(scriptContent, filePath)

requestModules(rootSandbox, modulesInUse)

table.freeze(rootSandbox)

luau.load(scriptContent, rootSandbox)()
