AddCSLuaFile()

module("bpcompiler", package.seeall, bpcommon.rescope(bpschema, bpcommon))

CF_None = 0
CF_Standalone = 1
CF_Comments = 2
CF_Debug = 4
CF_ILP = 8
CF_CodeString = 16

CF_Default = bit.bor(CF_Comments, CF_Debug, CF_ILP)

CP_PREPASS = 0
CP_MAINPASS = 1
CP_NETCODEMSG = 2
CP_ALLOCVARS = 3

TK_GENERIC = 0
TK_NETCODE = 1

-- Context prefixes, a context stores lines of code
CTX_SingleNode = "singlenode_"
CTX_FunctionNode = "functionnode_"
CTX_Graph = "graph_"
CTX_JumpTable = "jumptable_"
CTX_MetaTables = "metatables_"
CTX_Vars = "vars_"
CTX_Code = "code"
CTX_MetaEvents = "metaevents_"
CTX_Hooks = "hooks_"
CTX_Network = "network"
CTX_NetworkMeta = "networkmeta"
CTX_Thunk = "thunk"

local meta = bpcommon.MetaTable("bpcompiler")

function meta:Init( mod, flags )

	self.flags = flags or CF_Default
	self.module = mod
	self.indent = 0

	-- context control functions
	self.pushIndent = function() self.indent = self.indent + 1 end
	self.popIndent = function() self.indent = self.indent - 1 end
	self.begin = function(ctx)
		self.current_context = ctx
		self.buffer = {}
	end
	self.emit = function(text)
		if self.indent ~= 0 then text = string.rep("\t", self.indent) .. text end
		table.insert(self.buffer, text)
	end
	self.emitBlock = function(text)
		local lines = string.Explode("\n", text)
		local minIndent = nil
		for _, line in pairs(lines) do
			local _, num = string.find(line, "\t+")
			if num then minIndent = math.min(num, minIndent or 10) else minIndent = 0 end
		end
		local commonIndent = "^" .. string.rep("\t", minIndent)
		for k, line in pairs(lines) do
			line = minIndent == 0 and line or line:gsub(commonIndent, "")
			if line ~= "" or k ~= #lines then self.emit(line) end
		end
	end
	self.emitIndented = function(lines, tabcount)
		local t = string.rep("\t", tabcount or 0)
		for _, l in pairs(lines) do
			self.emit( t .. l )
		end
	end
	self.emitContext = function(context, tabcount)
		self.emitIndented( self.getContext( context ), tabcount )
	end
	self.finish = function()
		self.contexts[self.current_context] = self.buffer
		self.buffer = {}
		self.current_context = nil
	end
	self.getContext = function(ctx)
		if not self.contexts[ctx] then error("Compiler context not found: '" .. ctx .. "'") end
		return self.contexts[ctx]
	end
	self.getFilteredContexts = function(filter)
		local out = {}
		for k,v in pairs(self.contexts) do
			if string.find(k, filter) ~= nil then out[k] = v end
		end
		return out
	end

	return self

end

function meta:Setup()

	self.thunks = {}
	self.compiledNodes = {}
	self.graphs = {}
	self.vars = {}
	self.nodejumps = {}
	self.contexts = {}
	self.current_context = nil
	self.buffer = ""
	self.debug = bit.band(self.flags, CF_Debug) ~= 0
	self.debugcomments = bit.band(self.flags, CF_Comments) ~= 0
	self.ilp = bit.band(self.flags, CF_ILP) ~= 0
	self.ilpmax = 10000
	self.ilpmaxh = 4
	self.guidString = bpcommon.GUIDToString(self.module:GetUID(), true)
	self.varscope = nil
	self.pinRouters = {}

	return self

end

function meta:AllocThunk(type)
	
	self.thunks[type] = self.thunks[type] or {}
	local t = self.thunks[type]

	local id = #t + 1
	table.insert(t, {
		context = CTX_Thunk .. "_" .. type .. "_" .. id,
		begin = function()
			self.begin(CTX_Thunk .. "_" .. type .. "_" .. id)
		end,
		emit = self.emit,
		emitBlock = self.emitBlock,
		finish = function()
			self.finish()
		end,
		id = id,
	})
	return t[id]

end

function meta:GetThunk(type, id)

	return self.thunks[type][id]

end

local codenames = {
	["!"] = "__CH~EX__",
	["@"] = "__CH~AT__",
	["%"] = "__CH~PE__",
	["$"] = "__CH~DO__",
	["^"] = "__CH~CA__",
	["#"] = "__CH~HA__",
	["\\n"] = "__CH~NL__",
}

local nodeTypeEnumerateData = {
	[NT_Pure] = { unique = false },
	[NT_Function] = { unique = true },
	[NT_Event] = { unique = true },
	[NT_Special] = { unique = true },
	[NT_FuncInput] = { unique = true },
	[NT_FuncOutput] = { unique = true },
}

function SanitizeString(str)

	local r = str:gsub("\\n", "__CH~NL__")
	r = r:gsub("\\", "\\\\")
	r = r:gsub("\"", "\\\"")
	r = r:gsub("[%%!@%^#]", function(x)
		return codenames[x] or "INVALID"
	end)
	return r

end

function DesanitizeCodedString(str)

	for k,v in pairs(codenames) do
		str = str:gsub(v, k == "%" and "%%" or k)
	end
	return str

end

function meta:CreateNodeVar(node, identifier, isGlobal)

	local key = bpcommon.CreateUniqueKey(self.varscope, "local_" .. node:GetTypeName() .. "_v_" .. identifier)
	local v = {
		var = key,
		localvar = identifier,
		node = node,
		graph = node:GetGraph(),
		keyAsGlobal = isGlobal,
	}

	table.insert(self.vars, v)
	return v

end

function meta:CreatePinRouter(pin, func)

	self.pinRouters[pin] = func

end

-- creates a variable for the specified pin
function meta:CreatePinVar(pin)

	local node = pin:GetNode()
	local graph = node:GetGraph()
	local graphName = self.graph:GetName()
	local pinName = pin:GetName()
	local codeType = node:GetCodeType()
	local isFunctionPin = codeType == NT_FuncInput or codeType == NT_FuncOutput
	local unique = self.varscope
	local pinStr = node:ToString(pin)

	pinName = (pinName ~= "" and pinName or "pin")

	if pin:IsType(PN_Exec) then return nil end
	if pin:IsIn() then

		if isFunctionPin then

			local key = bpcommon.CreateUniqueKey({}, "func_" .. graphName .. "_out_" .. pinName)
			table.insert(self.vars, {
				var = key,
				pin = pin,
				graph = graph,
				output = true,
				isFunc = true,
			})
			return self.vars[#self.vars]

		end

	elseif pin:IsOut() then

		if not isFunctionPin then

			local key = bpcommon.CreateUniqueKey(unique, "fcall_" .. node:GetTypeName() .. "_ret_" .. pinName)
			table.insert(self.vars, {
				var = key,
				global = codeType ~= NT_Pure,
				pin = pin,
				graph = graph,
				isFunc = isFunctionPin,
			})
			return self.vars[#self.vars]

		else

			local key = bpcommon.CreateUniqueKey(unique, "func_" .. graphName .. "_in_" .. pinName)
			table.insert(self.vars, {
				var = key,
				pin = pin,
				graph = graph,
				isFunc = isFunctionPin,
			})

		end

	end

end

--[[
This function goes through all nodes of a certain type in the current graph and creates variable entries for them.
These variables are used to connect node outputs to inputs among other things

There are currently 2 types of vars:
	node-locals and return-values

Node-locals are internal variables scoped to a specific node.
The foreach node uses this to keep track of its iteration.

Return-values hold the output of non-pure function calls.
]]

function meta:CreateFunctionGraphVars(uniqueKeys)

	local unique = uniqueKeys
	local name = self.graph:GetName()
	local key = bpcommon.CreateUniqueKey(unique, "func_" .. name .. "_returned")

	table.insert(self.vars, {
		var = key,
		graph = self.graph,
		isFunc = true,
	})

end

function meta:EnumerateGraphVars(uniqueKeys)

	local localScopeUnique = {}
	for nodeID, node in self.graph:Nodes() do

		local e = nodeTypeEnumerateData[node:GetCodeType()]
		if not e then continue end

		local unique = e.unique and uniqueKeys or localScopeUnique
		self.varscope = unique

		if not self:RunNodeCompile(node, CP_ALLOCVARS) then

			for _, l in pairs(node:GetLocals()) do self:CreateNodeVar(node, l, false) end
			for _, l in pairs(node:GetGlobals()) do self:CreateNodeVar(node, l, true) end
			for pinID, pin in node:Pins() do self:CreatePinVar(pin) end

		end

		self.varscope = nil

	end

end

-- find a node-local variable by name for a given node
function meta:FindVarForNode(node, vname)

	for k,v in pairs(self.vars) do

		if not v.localvar then continue end
		if v.graph ~= self.graph then continue end
		if v.node == node and v.localvar == vname then return v end

	end

end

-- find the variable that is assigned to the given node/pin
function meta:FindVarForPin(pin, noLiteral)

	if self.pinRouters[pin] then
		return self.pinRouters[pin](pin)
	end

	for k,v in pairs(self.vars) do

		if v.localvar then continue end
		if v.graph ~= self.graph then continue end
		if pin ~= nil then 
			if v.pin == pin then return v end
		else
			if v.pin == nil then return v end
		end

	end

	--if pin then error("Var not found for pin: " .. pin:GetNode():ToString(pin)) end

end

function meta:GetPinLiteral(pin)

	local node = pin:GetNode()
	if node and node.literals[pin.id] ~= nil and not noLiteral then
		local l = tostring(node.literals[pin.id])
		if pin:IsType(PN_String) then l = "\"" .. SanitizeString(l) .. "\"" end

		return { var = l }
	end

end


-- basically just adds a self prefix for global variables to scope them into the module
function meta:GetVarCode(var, jump)

	if var == nil then
		error("Failed to get var for " .. self.currentNode:ToString() .. " ``" .. tostring(self.currentCode) .. "``" )
	end

	local s = ""
	if jump and var.jump then s = "goto jmp_" end
	if var.literal then return s .. var.var end
	if var.global or var.isFunc or var.keyAsGlobal then return "__self." .. var.var end
	return s .. var.var

end

function meta:GetPinCode(pin, ...)

	local var = self:GetPinVar(pin)
	return self:GetVarCode(var, ...)

end

-- finds or creates a jump table for the current graph
function meta:GetGraphJumpTable()

	local graphID = self.graph.id
	self.nodejumps[graphID] = self.nodejumps[graphID] or {}
	return self.nodejumps[graphID]

end

-- replaces meta-code in the node type (see top of defspec.txt) with references to actual variables
function meta:CompileVars(code, inVars, outVars, nodeID)

	local str = code
	local node = self.graph:GetNode(nodeID)
	local inBase = 0
	local outBase = 0

	self.currentNode = node
	self.currentCode = str

	if node:GetCodeType() == NT_Function then
		inBase = 1
		outBase = 1
	end

	-- replace macros
	str = string.Replace( str, "@graph", "graph_" .. self.graph.id .. "_entry" )
	str = string.Replace( str, "!node", tostring(nodeID))
	str = string.Replace( str, "!graph", tostring(self.graph.id))
	str = string.Replace( str, "!module", tostring(self.guidString))

	-- replace input pin codes
	str = str:gsub("$(%d+)", function(x) return self:GetVarCode(inVars[tonumber(x) + inBase]) end)

	-- replace output pin codes
	str = str:gsub("#_(%d+)", function(x) return self:GetVarCode(outVars[tonumber(x) + outBase]) end)
	str = str:gsub("#(%d+)", function(x) return self:GetVarCode(outVars[tonumber(x) + outBase], true) end)

	local lmap = {}
	for k,v in pairs(node:GetLocals()) do
		local var = self:FindVarForNode(node, v)
		if var == nil then error("Failed to find internal variable: " .. tostring(v)) end
		lmap[v] = var
	end

	for k,v in pairs(node:GetGlobals()) do
		local var = self:FindVarForNode(node, v)
		if var == nil then error("Failed to find internal variable: " .. tostring(v)) end
		lmap[v] = var
	end

	str = str:gsub("%%([%w_]+)", function(x)
		if not lmap[x] then error("FAILED TO FIND LOCAL: " .. tostring(x)) end
		return self:GetVarCode(lmap[x]) end
	)

	-- replace jumps
	local jumpTable = self:GetGraphJumpTable()[nodeID] or {}
	str = str:gsub("%^_([%w_]+)", function(x) return tostring(jumpTable[x]) end)
	str = str:gsub("%^([%w_]+)", function(x) return "jmp_" .. jumpTable[x] end)
	str = DesanitizeCodedString(str)

	if node:GetCodeType() == NT_Function then
		str = str .. "\n" .. self:GetVarCode(outVars[1], true)
	end

	return str

end

-- If pin is connected, gets the connected var. Otherwise creates a literal if applicable
function meta:GetPinVar(pin)

	local node = pin:GetNode()
	local codeType = node:GetCodeType()
	local pins = pin:GetConnectedPins()

	if pin:IsIn() then

		if #pins == 1 then

			local var = self:FindVarForPin(pins[1])
			if var == nil then error("COULDN'T FIND INPUT VAR FOR " .. pins[1]:GetNode():ToString(pins[1])) end
			return var

		-- if there are no connections, try to assign literals on this pin
		elseif #pins == 0 then

			local literalVar = self:GetPinLiteral(pin)
			if literalVar ~= nil then
				return literalVar
			else
				-- unconnected nullable pins just have their value set to nil
				local nullable = pin:HasFlag(PNF_Nullable)
				if nullable then
					return { var = "nil" }
				else
					error("Pin must be connected: " .. node:ToString(pin))
				end
			end
		else
			error("No handler for multiple input pins")
		end

	elseif pin:IsOut() then

		if codeType == NT_Event then
			return self:FindVarForPin(pin)
		else

			if pin:IsType(PN_Exec) then

				-- unconnected exec pins jump to ::jmp_0:: which just pops the stack
				return {
					var = #pins == 0 and "0" or pins[1]:GetNode().id,
					jump = true,
				}

			else

				-- find output variable to write to on this pin
				local var = self:FindVarForPin(pin)
				if var == nil then error("Unable to find var for pin " .. node:ToString(pin)) end
				return var

			end

		end

	end

end

-- compiles a single node
function meta:CompileNodeSingle(nodeID)

	local node = self.graph:GetNode(nodeID)
	local code = node:GetCode()
	local codeType = node:GetCodeType()
	local graphThunk = node:GetGraphThunk()

	self.currentNode = node
	self.currentCode = str

	-- TODO: Instead of building these strings, find a more direct approach of compiling these
	-- generate code based on function graph inputs and outputs
	if graphThunk ~= nil then
		local target = self.module:GetGraph( graphThunk )
		--print("---------------GRAPH THUNK: " .. ntype.graphThunk .. "---------------------------")
		code = ""
		local n = target.outputs:Size()
		for i=1, n do
			code = code .. "#" .. i .. (i~=n and ", " or " ")
		end
		if n ~= 0 then code = code .. "= " end
		code = code .. "__self:" .. target:GetName() .. "("
		local n = target.inputs:Size()
		for i=1, n do
			code = code .. "$" .. i .. (i~=n and ", " or "")
		end
		code = code .. ")"
		--print(code)
	end

	-- tie function input pins
	if codeType == NT_FuncInput then
		code = ""
		local ipin = 2
		for k, v in node:SidePins(PD_Out) do
			if v:IsType(PN_Exec) then continue end
			code = code .. "#" .. k .. " = arg[" .. ipin-1 .. "]\n"
			ipin = ipin + 1
		end

		if code:len() > 0 then code = code:sub(0, -2) end
	end

	if codeType == NT_FuncOutput then
		code = ""
		local ipin = 2
		for k, v in node:SidePins(PD_In) do
			if v:IsType(PN_Exec) then continue end
			code = code .. "#" .. k .. " = $" .. k .. "\n"
			ipin = ipin + 1
		end

		local ret = self:FindVarForPin(nil, true)
		code = code .. self:GetVarCode(ret) .. " = true\n"
		code = code .. "goto __terminus\n"

		if code:len() > 0 then code = code:sub(0, -2) end
	end

	if not code then
		ErrorNoHalt("No code for node: " .. node:ToString() .. "\n")
		return
	end

	-- the context to emit (singlenode_graph#_node#)
	self.begin(CTX_SingleNode .. self.graph.id .. "_" .. nodeID)

	-- list of inputs/outputs to compile
	local inVars = {}
	local outVars = {}

	-- iterate through all input pins
	for pinID, pin, pos in node:SidePins(PD_In) do
		if pin:IsType(PN_Exec) then continue end

		if codeType == NT_FuncOutput then
			outVars[pos] = self:FindVarForPin(pin, true)
		end

		inVars[pos] = self:GetPinVar(pin)

	end

	-- iterate through all output pins
	for pinID, pin, pos in node:SidePins(PD_Out) do
		
		outVars[pos] = self:GetPinVar(pin)

	end	

	-- grab code off node type and remove tabs
	code = string.Replace(code, "\t", "")

	-- take all the mapped variables and place them in the code string
	code = Profile("vct", self.CompileVars, self, code, inVars, outVars, nodeID)

	-- emit some infinite-loop-protection code
	if self.ilp and (codeType == NT_Function or codeType == NT_Special or codeType == NT_FuncOutput) then
		self.emit("__ilp = __ilp + 1 if __ilp > " .. self.ilpmax .. " then __ilptrip = true goto __terminus end")
	end

	-- and debugging info
	if self.debug then
		self.emit("__dbgnode = " .. nodeID)
	end

	-- node can compile itself if needed
	if self:RunNodeCompile(node, CP_MAINPASS) then


	else

		-- break the code apart and emit each line
		for _, l in pairs(string.Explode("\n", code)) do
			self.emit(l)
		end

	end

	self.finish()

end

-- given a non-pure function, walk back through the tree of pure nodes that contribute to its inputs
-- traversal order follows proceedural execution of nodes (inputs traversed, then node)
function meta:WalkBackPureNodes(nodeID, call)

	local max = 10000
	local stack = {}
	local output = {}

	table.insert(stack, nodeID)

	while #stack > 0 and max > 0 do

		max = max - 1

		local pnode = stack[#stack]
		table.remove(stack, #stack)

		for pinID, pin in self.graph:GetNode(pnode):SidePins(PD_In) do

			local connections = pin:GetConnectedPins()
			for _, v in pairs(connections) do

				local node = v:GetNode()
				if node:GetCodeType() == NT_Pure then
					table.insert(stack, node.id)
					table.insert(output, node.id)
				end

			end

		end

	end

	if max == 0 then
		error("Infinite pure-node loop in graph")
	end

	for i=#output, 1, -1 do
		call(output[i])
	end

end

-- compiles a non-pure function by collapsing all connected pure nodes into it and emitting labels/jumps
function meta:CompileNodeFunction(nodeID)

	local node = self.graph:GetNode(nodeID)
	local codeType = node:GetCodeType()

	self.begin(CTX_FunctionNode .. self.graph.id .. "_" .. nodeID)
	if self.debugcomments then self.emit("-- " .. node:ToString()) end
	self.emit("::jmp_" .. nodeID .. "::")

	-- event nodes are really just jump stubs
	if codeType == NT_Event or codeType == NT_FuncInput then 

		for pinID, pin in node:SidePins(PD_Out) do
			local pinType = self.graph:GetPinType( nodeID, pinID )
			if not pinType:IsType(PN_Exec) then continue end

			-- get the exec pin's connection and jump to the node it's connected to
			local connection = pin:GetConnectedPins()[1]
			if connection ~= nil then
				self.emit("\tgoto jmp_" .. connection:GetNode().id)
				self.finish()
				return
			end
		end
		
		-- unconnected exec pins just pop the callstack
		self.emit("\tgoto popcall")
		self.finish()
		return

	end

	-- walk through all connected pure nodes, emit each node's code context once
	local emitted = {}
	self:WalkBackPureNodes(nodeID, function(pure)
		if emitted[pure] then return end
		emitted[pure] = true
		self.emitContext( CTX_SingleNode .. self.graph.id .. "_" .. pure, 1 )
	end)

	-- emit this non-pure node's code
	self.emitContext( CTX_SingleNode .. self.graph.id .. "_" .. nodeID, 1 )

	self.finish()

end

-- emits some boilerplate code for indexing gmod's metatables
function meta:CompileMetaTableLookup()

	self.begin(CTX_MetaTables)

	local tables = {}

	-- Collect all used types from module and write out the needed meta tables
	local types = self.module:GetUsedPinTypes(nil, true)
	for _, t in pairs(types) do

		local baseType = t:GetBaseType()
		if baseType == PN_Ref then

			local class = bpdefs.Get():GetClass(t)
			table.insert(tables, class.name)

		elseif baseType == PN_Struct then

			local struct = bpdefs.Get():GetStruct(t)
			local metaTable = struct and struct:GetMetaTable() or nil
			if metaTable then
				table.insert(tables, metaTable)
			end

		elseif baseType == PN_Vector then

			table.insert(tables, "Vector")

		elseif baseType == PN_Angles then

			table.insert(tables, "Angle")

		elseif baseType == PN_Color then

			table.insert(tables, "Color")

		end

	end

	-- Some nodes require access to additional metatables, process them here
	for _, graph in self.module:Graphs() do
		for _, node in graph:Nodes() do
			local rm = node:GetRequiredMeta()
			if not rm then continue end
			for _, m in pairs(rm) do
				if not table.HasValue(tables, m) then table.insert(tables, m) end
			end
		end
	end

	for k, v in pairs(tables) do
		self.emit("local " .. v ..  "_ = FindMetaTable(\"" .. v .. "\")")
	end

	self.finish()

end

-- lua doesn't have a switch/case construct, so build a massive 'if' bank to jump to each section of the code.
function meta:CompileGraphJumpTable()

	self.begin(CTX_JumpTable .. self.graph.id)

	local nextJumpID = 0

	-- jmp_0 just pops the call stack
	self.emit( "if ip == 0 then goto jmp_0 end" )

	-- emit jumps for all non-pure functions
	for id, node in self.graph:Nodes() do
		if node:GetCodeType() ~= NT_Pure then
			self.emit( "if ip == " .. id .. " then goto jmp_" .. id .. " end" )
		end
		nextJumpID = math.max(nextJumpID, id+1)
	end

	-- some nodes have internal jump symbols to control program flow (delay / sequence)
	-- create jump vectors for each of those
	local jumpTable = self:GetGraphJumpTable()
	for id, node in self.graph:Nodes() do
		for _, j in pairs(node:GetJumpSymbols()) do

			jumpTable[id] = jumpTable[id] or {}
			jumpTable[id][j] = nextJumpID
			self.emit( "if ip == " .. nextJumpID .. " then goto jmp_" .. nextJumpID .. " end" )
			nextJumpID = nextJumpID + 1

		end
	end

	self.finish()

end

-- builds global variable initializer code for module construction
function meta:CompileGlobalVarListing()

	self.begin(CTX_Vars .. "global")

	for k, v in pairs(self.vars) do
		if not v.literal and v.global then
			self.emit("instance." .. v.var .. " = nil")
		end
		if v.localvar and v.keyAsGlobal then
			self.emit("instance." .. v.var .. " = nil")
		end
	end

	for id, var in self.module:Variables() do
		local def = var.default
		if var:GetType() == PN_String and bit.band(var:GetFlags(), PNF_Table) == 0 then def = "\"\"" end
		self.emit("instance.__" .. var.name .. " = " .. tostring(def))
	end

	self.finish()

end

-- builds local variable initializer code for graph entry function
function meta:CompileGraphVarListing()

	self.begin(CTX_Vars .. self.graph.id)

	for k, v in pairs(self.vars) do
		if v.graph ~= self.graph then continue end
		if not v.literal and not v.global and not v.isFunc and not v.keyAsGlobal then
			self.emit("local " .. v.var .. " = nil")
		end
	end

	self.finish()

end

-- compiles the graph entry function
function meta:CompileGraphEntry()

	local graphID = self.graph.id

	self.begin(CTX_Graph .. graphID)

	-- graph function header and callstack
	self.emit("\nlocal function graph_" .. graphID .. "_entry( ip )\n")
	self.emit("\tlocal cs = {}")

	-- debugging info
	if self.debug then
		self.emit( "\t__dbggraph = " .. graphID)
	end

	-- emit graph-local variables
	self.emitContext( CTX_Vars .. graphID, 1 )

	-- emit jump table
	self.emit( "\tlocal function pushjmp(i) table.insert(cs, 1, i) end")
	self.emit( "\tgoto jumpto" )
	self.emit( "\n\t::jmp_0:: ::popcall::\n\tif #cs > 0 then ip = cs[1] table.remove(cs, 1) else goto __terminus end" )
	self.emit( "\n\t::jumpto::" )

	self.emitContext( CTX_JumpTable .. graphID, 1 )

	-- emit all functions belonging to this graph
	local code = self.getFilteredContexts( CTX_FunctionNode .. self.graph.id )
	for k, _ in pairs(code) do
		self.emitContext( k, 1 )
	end

	-- emit terminus jump vector
	self.emit("\n\t::__terminus::\n")
	self.emit("end")

	self.finish()

	--print(table.concat( self.getContext( CTX_Graph .. self.graph.id ), "\n" ))

end

function meta:CompileNetworkCode()

	self.begin(CTX_Network)

	if bit.band(self.flags, CF_Standalone) ~= 0 then

		self.emitBlock [[
		if SERVER then
			util.AddNetworkString("bphandshake")
			util.AddNetworkString("bpmessage")
			util.AddNetworkString("bpclosechannel")
		end
		]]

	end

	self.emitBlock [[
	G_BPNetHandlers = G_BPNetHandlers or {}
	G_BPNetChannels = G_BPNetChannels or {}
	net.Receive("bpclosechannel", function(len, pl)
		local channelID = net.ReadUInt(16)
		G_BPNetChannels[channelID] = nil
		print("Net close netchannel: " .. channelID)
	end)
	net.Receive("bphandshake", function(len, pl)
		local moduleGUID = net.ReadData(16)
		local instanceGUID = net.ReadData(16)
		for _, v in pairs(G_BPNetHandlers) do
			if v.__bpm.guid ~= moduleGUID then continue end
			v:netReceiveHandshake(instanceGUID, len, pl)
		end
	end)
	net.Receive("bpmessage", function(len, pl)
		local channelID = net.ReadUInt(16)
		local channel = G_BPNetChannels[channelID]
		if channel ~= nil then channel:netReceiveMessage(len, pl) end
	end)
	]]

	self.finish()

	self.begin(CTX_NetworkMeta)

	self.emitBlock [[
	function meta:allocChannel(id, guid)
		if (id or -1) == -1 then for i=0, 65535 do if G_BPNetChannels[i] == nil then id = i break end end end
		if id == -1 then error("Unable to allocate network channel") end
		if G_BPNetChannels[id] then print("WARNING: Network channel already allocated: " .. id) end
		G_BPNetChannels[id] = self
		return { id = id, guid = guid }
	end
	function meta:closeChannel(ch)
		if ch == nil then return end
		if G_BPNetChannels[ch.id] == nil then return end
		print("Free netchannel: " .. ch.id)
		G_BPNetChannels[ch.id] = nil
		if SERVER then
			net.Start("bpclosechannel")
			net.WriteUInt(ch.id, 16)
			net.Broadcast()
		end
	end
	function meta:netInit()
		print("Net init")
		self.netReady = false
		self.netPendingCalls = {}
		table.insert(G_BPNetHandlers, self)
		if CLIENT then
			net.Start("bphandshake")
			net.WriteData(__bpm.guid, 16)
			net.WriteData(self.guid, 16)
			net.WriteBool(false)
			net.SendToServer()
		else
			self.netChannel = self:allocChannel(nil, self.guid)
		end
	end
	function meta:netShutdown()
		print("Net shutdown")
		self:closeChannel(self.netChannel)
		table.RemoveByValue(G_BPNetHandlers, self)
	end
	function meta:netUpdate()
		if not self.netReady then return end
		local pc = self.netPendingCalls[1]
		while pc ~= nil do
			pc()
			table.remove(self.netPendingCalls, 1)
			pc = self.netPendingCalls[1]
		end
	end
	function meta:netPostCall(func)
		table.insert(self.netPendingCalls, func)
	end
	function meta:netReceiveHandshake(instanceGUID, len, pl)
		if SERVER then
			local ready = net.ReadBool()
			if not ready and instanceGUID == self.guid then
				print("Recv handshake request from: " .. tostring(pl))
				net.Start("bphandshake")
				net.WriteData(__bpm.guid, 16)
				net.WriteData(instanceGUID, 16)
				net.WriteUInt(self.netChannel.id, 16)
				net.Send(pl)
				print("Handshake Establish Channel: " .. self.netChannel.id .. " -> " .. __bpm.guidString(self.guid))
			else
				print("Channel established on both roles: " .. self.netChannel.id .. " -> " .. __bpm.guidString(self.guid))
				self.netReady = true
			end
		else
			local id = net.ReadUInt(16)
			if instanceGUID == self.guid then
				self.netChannel = self:allocChannel(id, self.guid)
				print("Handshake Establish Channel: " .. self.netChannel.id .. " -> " .. __bpm.guidString(self.guid))
				net.Start("bphandshake")
				net.WriteData(__bpm.guid, 16)
				net.WriteData(self.guid, 16)
				net.WriteBool(true)
				net.SendToServer()
				self.netReady = true
			end
		end
	end
	function meta:netWriteTable(f, t)
		net.WriteUInt(#t, 24)
		for i=1, #t do
			f(t[i])
		end
	end
	function meta:netReadTable(f)
		local t = {}
		local n = net.ReadUInt(24)
		for i=1, n do
			table.insert(t, f())
		end
		return t
	end
	function meta:netStartMessage(id)
		net.Start("bpmessage")
		net.WriteUInt(self.netChannel.id, 16)
		net.WriteUInt(id, 16)
	end
	function meta:netReceiveMessage(len, pl)
		local msgID = net.ReadUInt(16)]]

		self.pushIndent()

		for _, graph in pairs(self.graphs) do
			for _, node in graph:Nodes() do
				self:RunNodeCompile(node, CP_NETCODEMSG)
			end
		end

		self.popIndent()

	self.emitBlock [[
	end
	]]

	self.finish()

end

-- glues all the code together
function meta:CompileCodeSegment()

	self.begin(CTX_Code)

	if bit.band(self.flags, CF_Standalone) ~= 0 then
		self.emit("AddCSLuaFile()")
	end

	--self.emit("if SERVER then util.AddNetworkString(\"bphandshake\") end")
	--self.emit("if SERVER then util.AddNetworkString(\"bpmessage\") end\n")

	self.emitContext( CTX_MetaTables )
	self.emit("local __self = nil")

	-- debugging and infinite-loop-protection
	if self.debug then
		self.emitBlock [[
		local __dbgnode = -1
		local __dbggraph = -1
		]]
	end

	if self.ilp then
		self.emitBlock [[
		local __ilptrip = false
		local __ilp = 0
		local __ilph = 0
		]]
	end

	-- __bpm is the module table, it contains utilities and listings for module functions
	self.emit("local __bpm = {}")

	self.emitContext( CTX_Network )

	-- emit each graph's entry function
	for id in self.module:GraphIDs() do
		self.emitContext( CTX_Graph .. id )
	end

	-- infinite-loop-protection checker
	if self.ilp then
		self.emitBlock ([[
		__bpm.checkilp = function()
			if __ilph > ]] .. self.ilpmaxh .. [[ then __bpm.onError("Infinite loop in hook", ]] .. self.module.id .. [[, __dbggraph or -1, __dbgnode or -1) return true end
			if __ilptrip then __bpm.onError("Infinite loop", ]] .. self.module.id .. [[, __dbggraph or -1, __dbgnode or -1) return true end
		end
		]])
	end

	-- metatable for the module
	self.emitBlock [[
	local meta = BLUEPRINT_OVERRIDE_META or {}
	if BLUEPRINT_OVERRIDE_META == nil then meta.__index = meta end
	__bpm.meta = meta
	__bpm.guidString = function(g)
		return ("%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X%0.2X"):format(
			g[1]:byte(),g[2]:byte(),g[3]:byte(),g[4]:byte(),g[5]:byte(),g[6]:byte(),g[7]:byte(),g[8]:byte(),
			g[9]:byte(),g[10]:byte(),g[11]:byte(),g[12]:byte(),g[13]:byte(),g[14]:byte(),g[15]:byte(),g[16]:byte())
	end
	__bpm.hexBytes = function(str) return str:gsub("%w%w", function(x) return string.char(tonumber(x[1],16) * 16 + tonumber(x[2],16)) end) end
	__bpm.genericIsValid = function(x) return type(x) == 'number' or type(x) == 'boolean' or IsValid(x) end
	]]

	self.emit("__bpm.guid = __bpm.hexBytes(\"" .. bpcommon.GUIDToString(self.module:GetUID(), true) .. "\")")

	-- delay manager (so that delays can be cancelled when a module is unloaded)
	self.emitBlock [[
	__bpm.delayExists = function(key)
		for i=#__self.delays, 1, -1 do if __self.delays[i].key == key then return true end end
		return false
	end
	__bpm.delay = function(key, delay, func)
		for i=#__self.delays, 1, -1 do if __self.delays[i].key == key then table.remove(__self.delays, i) end end
		table.insert( __self.delays, { key = key, func = func, time = delay })
	end
	]]


	-- error management, allows for custom error handling with debug info about which node / graph the error happened in
	self.emit("__bpm.onError = function(msg, mod, graph, node) end")

	-- network meta functions
	self.emitContext( CTX_NetworkMeta )

	-- update function, runs delays and resets the ilp recursion value for hooks
	self.emit("function meta:update()")
	self.pushIndent()

	if self.ilp then self.emit("__ilph = 0") end
	self.emitBlock [[
	self:netUpdate()
	for i=#self.delays, 1, -1 do
		self.delays[i].time = self.delays[i].time - FrameTime()
		if self.delays[i].time <= 0 then
			local s,e = pcall(self.delays[i].func)
			if not s then self.delays = {} __bpm.onError(e:sub((e:find(':', 11) or 0)+2, -1), " .. self.module.id .. ", __dbggraph or -1, __dbgnode or -1) end
			table.remove(self.delays, i)
		end
	end
	]]

	self.popIndent()
	self.emit("end")

	-- emit all meta events (functions with graph entry points)
	for k, _ in pairs( self.getFilteredContexts(CTX_MetaEvents) ) do
		self.emitContext( k )
	end

	-- minified guid generator
	self.emitBlock [[
	__bpm.makeGUID = function()
		local d,b,g,m=os.date"*t",function(x,y)return x and y or 0 end,system,bit
		local r,n,s,u,x,y=function(x,y)return m.band(m.rshift(x,y or 0),0xFF)end,
		math.random(2^32-1),_G.__guidsalt or b(CLIENT,2^31),os.clock()*1000,
		d.min*1024+d.hour*32+d.day,d.year*16+d.month;_G.__guidsalt=s+1;return
		string.char(r(x),r(x,8),r(y),r(y,8),r(n,24),r(n,16),r(n,8),r(n),r(s,24),r(s,16),
		r(s,8),r(s),r(u,16),r(u,8),r(u),d.sec*4+b(g.IsWindows(),2)+b(g.IsLinux(),1))
	end
	]]

	-- constructor
	self.emit("__bpm.new = function()")
	self.emit("\tlocal instance = setmetatable({}, meta)")
	self.emit("\tinstance.delays = {}")
	self.emit("\tinstance.__bpm = __bpm")
	self.emit("\tinstance.guid = __bpm.makeGUID()")
	self.emitContext( CTX_Vars .. "global", 1 )
	self.emit("\treturn instance")
	self.emit("end")

	-- event listing
	self.emit("__bpm.events = {")
	for k, _ in pairs( self.getFilteredContexts(CTX_Hooks) ) do
		self.emitContext( k, 1 )
	end
	self.emit("}")

	-- assign local to _G.__BPMODULE so we can grab it from RunString
	self.emit("__BPMODULE = __bpm")

	if bit.band(self.flags, CF_Standalone) ~= 0 then

		self.emitBlock [[
		local instance = __bpm.new()
		if instance.CORE_Init then instance:CORE_Init() end
		local bpm = instance.__bpm
		for k,v in pairs(bpm.events) do
			if not v.hook or type(meta[k]) ~= "function" then continue end
			local function call(...) return instance[k](instance, ...) end
			local key = "bphook_" .. instance.__guid
			hook.Add(v.hook, key, call)
		end
		]]

	end

	self.finish()

end

function meta:RunNodeCompile(node, pass)

	local ntype = node:GetType()
	if ntype.Compile then return ntype.Compile(node, self, pass) end
	return false

end

-- called on all graphs before main compile pass, generates all potentially shared data between graphs
function meta:PreCompileGraph(graph, uniqueKeys)

	self.graph = graph

	Profile("cache-node-types", function()
		self.graph:CacheNodeTypes()
	end)

	Profile("collapse-reroutes", function()
		self.graph:CollapseRerouteNodes()
	end)

	Profile("enumerate-graph-vars", function()

		-- 'uniqueKeys' is a table for keeping keys distinct, global variables must be distinct when each graph generates them.
		-- pure node variables do not need exclusive keys between graphs because they are local
		self:EnumerateGraphVars(uniqueKeys)

	end)

	if self.graph.type == GT_Function then
		Profile("create-function-vars", self.CreateFunctionGraphVars, self, uniqueKeys)
	end

	-- compile jump table and variable listing for this graph
	Profile("jump-table", self.CompileGraphJumpTable, self)
	Profile("var-listing", self.CompileGraphVarListing, self)

	Profile("graph-prepass", function()
		for id, node in self.graph:Nodes() do
			self:RunNodeCompile(node, CP_PREPASS)
		end
	end)

end

-- compiles a metamethod for a given event
function meta:CompileGraphMetaHook(graph, nodeID, name)

	local node = self.graph:GetNode(nodeID)

	self.currentNode = node
	self.currentCode = ""

	self.begin(CTX_MetaEvents .. name)

	self.emit("function meta:" .. name .. "(...)")
	self.pushIndent()

	-- build argument table and store reference to 'self'
	self.emit("local arg = {...}")
	self.emit("__self = self")

	-- emit the code for the event node
	self.emitContext( CTX_SingleNode .. self.graph.id .. "_" .. nodeID )

	-- infinite-loop-protection, prevents a loop case where an event calls a function which in turn calls the event.
	-- a counter is incremented and as recursion happens, the counter increases.
	if self.ilp then
		
		self.emitBlock [[
		if __bpm.checkilp() then return end __ilptrip=false __ilp=0 __ilph=__ilph+1
		]]

	end

	if self.graph:GetType() == GT_Function then
		self.emit(self:GetVarCode(self:FindVarForPin(nil)) .. " = false")
	end

	-- protected call into graph entrypoint, calls error handler on error
	self.emit("local b,e = pcall(graph_" .. self.graph.id .. "_entry, " .. nodeID .. ")")
	self.emit("if not b then __bpm.onError(tostring(e), " .. self.module.id .. ", __dbggraph or -1, __dbgnode or -1) end")

	-- infinite-loop-protection, after calling the event the counter is decremented.
	if self.ilp then
		self.emit("if __bpm.checkilp() then return end")
		self.emit("__ilph = __ilph - 1")
	end

	if self.graph:GetType() == GT_Function then
		self.emit("if " .. self:GetVarCode(self:FindVarForPin(nil)) .. " == true then")
		self.emit("return")

		local out = {}

		local emitted = {}
		for k,v in pairs(self.vars) do
			if emitted[v.var] then continue end
			if v.graph == self.graph and v.isFunc and v.output then
				table.insert(out, v)
				emitted[v.var] = true
			end
		end

		for k, v in pairs(out) do
			self.emit("\t" .. self:GetVarCode(v) .. (k == #out and "" or ","))
		end

		self.emit("end")
	end

	self.popIndent()
	self.emit("end")

	self.finish()

end

-- compile a full graph
function meta:CompileGraph(graph)

	self.graph = graph

	-- compile each single-node context in the graph
	for id in self.graph:NodeIDs() do
		Profile("single-node", self.CompileNodeSingle, self, id)
	end

	-- compile all non-pure function nodes in the graph (and events / special nodes)
	for id, node in self.graph:Nodes() do
		if node:GetCodeType() ~= NT_Pure then
			Profile("functions", self.CompileNodeFunction, self, id)
		end
	end

	-- compile all events nodes in the graph
	for id, node in self.graph:Nodes() do
		local codeType = node:GetCodeType()
		if codeType == NT_Event then
			self:CompileGraphMetaHook(graph, id, node:GetTypeName())
		elseif codeType == NT_FuncInput then
			self:CompileGraphMetaHook(graph, id, graph:GetName())
		end
	end

	-- compile graph's entry function
	Profile("graph-entries", self.CompileGraphEntry, self)

	--print("COMPILING GRAPH: " .. graph:GetName() .. " [" .. graph:GetFlags() .. "]")

	-- compile hook listing for each event (only events that have hook designations)
	self.begin(CTX_Hooks .. self.graph.id)

	for id, node in self.graph:Nodes() do
		local codeType = node:GetCodeType()
		local hook = node:GetHook()
		if codeType == NT_Event and hook then

			self.emit("[\"" .. node:GetTypeName() .. "\"] = {")

			self.pushIndent()
			self.emit("hook = \"" .. hook .. "\",")
			self.emit("graphID = " .. self.graph.id .. ",")
			self.emit("nodeID = " .. id .. ",")
			self.emit("moduleID = " .. self.module.id .. ",")
			self.popIndent()
			--self.emit("\t\tfunc = nil,")

			self.emit("},")

		end
	end

	if graph:HasFlag(bpgraph.FL_HOOK) then
		self.emit("[\"" .. graph:GetName() .. "\"] = {")

		self.pushIndent()
		self.emit("hook = \"" .. graph:GetName() .. "\",")
		self.emit("graphID = " .. graph.id .. ",")
		self.emit("nodeID = -1,")
		self.emit("moduleID = " .. self.module.id .. ",")
		self.emit("key = \"__bphook_" .. self.module.id .. "\"")
		self.popIndent()
		--self.emit("\t\tfunc = nil,")

		self.emit("},")
	end

	self.finish()

end

function meta:Compile()

	print("COMPILING MODULE...")

	ProfileStart("bpcompiler:Compile")

	self:Setup()

	Profile("meta-lookup", self.CompileMetaTableLookup, self)
	Profile("copy-graphs", function()

		-- make local copies of all module graphs so they can be edited without changing the module
		for id, graph in self.module:Graphs() do
			table.insert( self.graphs, graph:CopyInto( bpgraph.New() ) )
		end

	end)

	-- pre-compile all graphs in the module
	-- each graph shares a unique key table to ensure global variable names are distinct
	local uniqueKeys = {}
	for _, graph in pairs( self.graphs ) do
		Profile("pregraph", self.PreCompileGraph, self, graph, uniqueKeys )
	end

	-- compile the global variable listing (contains all global variables accross all graphs)
	Profile( "global-var-listing", self.CompileGlobalVarListing, self)

	-- compile each graph
	for _, graph in pairs( self.graphs ) do
		Profile("graph", self.CompileGraph, self, graph )
	end

	self:CompileNetworkCode()

	-- compile main code segment
	Profile("code-segment", self.CompileCodeSegment, self)

	self.compiled = table.concat( self.getContext( CTX_Code ), "\n" )

	ProfileEnd()

	-- write compiled output to file for debugging
	file.Write("blueprints/last_compile.txt", self.compiled)

	-- if set, just return the compiled string, don't try to run the module
	if bit.band(self.flags, CF_CodeString) ~= 0 then return true, self.compiled end

	-- run the code and grab the __BPMODULE global
	local errorString = RunString(self.compiled, "", false)
	if errorString then return false, errorString end

	local x = __BPMODULE
	__BPMODULE = nil

	return true, x

end

if SERVER and bpdefs ~= nil then

	local mod = bpmodule.New()
	local funcid, graph = mod:NewGraph("MyFunction", GT_Function)

	graph.outputs:Add( bpvariable.New(), "retvar" )
	graph.outputs:Add( bpvariable.New(), "retvar2" )
	graph.inputs:Add( bpvariable.New(), "testVar" )

	local graphid, graph = mod:NewGraph("Events", GT_Event)
	graph:AddNode("__Call" .. funcid)

	mod:Compile()

end

function New(...) return bpcommon.MakeInstance(meta, ...) end