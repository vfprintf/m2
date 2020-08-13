local driver = require "fhk.driver"
local conv = require "model.conv"
local code = require "code"
local reflect = require "lib.reflect"
local ffi = require "ffi"
local C = ffi.C

local function matcher(prefix)
	local pattern = "^" .. prefix .. "#(.+)$"
	return function(name)
		return name:match(pattern)
	end
end

---- groups ----------------------------------------

local pgroup_mt = { __index={} }

local function pgroup(name, ...)
	return setmetatable({
		match   = matcher(name),
		mappers = {...}
	}, pgroup_mt)
end

function pgroup_mt.__index:map_var(name)
	local lname = self.match(name)
	if not lname then return end

	local mapper, typ, create
	for _,m in ipairs(self.mappers) do
		local t,c = m:map_var(lname)

		if t then
			if mapper then
				error(string.format("Mapping conflict: '%s' (originally '%s') is claimed by"
				.. " multiple mappers: %s and %s", lname, name, mapper, m))
			end

			mapper, typ, create = m, t, c
		end
	end

	if not mapper then
		-- not mapped but prefix matched
		return true
	end

	return typ, create
end

function pgroup_mt.__index:map_model(name)
	return self.match(name) and true
end

function pgroup_mt.__index:shape_func(...)
	if #self.mappers == 0 then
		return function() return 0 end
	end

	if #self.mappers == 1 then
		return self.mappers[1]:shape_func(...)
	end

	local funs = {}

	-- TODO tästä alaspäin ei ole testiä

	for i,m in ipairs(self.mappers) do
		funs[i] = m:shape_func(...)
	end

	local sf = code.new()

	for i=1, #funs do
		sf:emitf("local shapef%d = funs[%d]", i, i)
	end

	sf:emit([[
		return function(state)
			local shape = shapef1(state)
			local s
	]])

	for i=2, #funs do
		sf:emitf([[
			s = shapef%d(state)
			if s ~= shape then goto fail end
		]], i)
	end

	-- hack: `if true` needed or the ::fail:: is a syntax error
	sf:emit([[
			if true then
				return shape
			end
::fail::
			error(string.format("Mappers disagree about shape: %d != %d", shape, s))
		end
	]])

	return sf:compile({funs=funs}, string.format("=(groupshape@%p)", self))()
end

---- mappings ----------------------------------------

-- struct mapper --------------------

local struct_mapper_mt = { __index={} }

local function struct_mapper(ctype, inst)
	return setmetatable({
		refct = reflect.typeof(ctype),
		inst  = inst
	}, struct_mapper_mt)
end

function struct_mapper_mt.__index:ref_gen(gen)
	if not gen[self] then
		gen[self] = gen:reserve(ffi.typeof("void *"))
		local inst = self.inst
		gen:init(function(state, _, ptr)
			ptr[0] = state[inst]       ---> ctype *
		end, gen[self])
	end

	return gen[self]
end

function struct_mapper_mt.__index:map_var(name)
	local field = self.refct:member(name)
	if not field then return end

	local create
	if type(self.inst) == "cdata" then
		local ptr = ffi.cast("uint8_t *", self.inst) + field.offset
		create = function()
			return driver.refk(ptr)  ---> ptr
		end
	else
		local offset = field.offset
		create = function(gen)
			return driver.refx(self:ref_gen(gen), offset)   ---> *udata + offset
		end
	end

	return conv.fromctype(field.type), create
end

local function shape1() return 1 end
function struct_mapper_mt.__index:shape_func()
	return shape1
end

-- vec mapper --------------------

local soa_mapper_mt = { __index={} }

local function soa_mapper(ctype, inst)
	return setmetatable({
		refct = reflect.typeof(ctype),
		inst  = inst
	}, soa_mapper_mt)
end

function soa_mapper_mt.__index:ref_gen(gen, alloc)
	if not gen[self] then
		gen[self] = gen:reserve(ffi.typeof("void *"))
		local inst = self.inst
		gen:init(function(state, _, ptr)
			ptr[0] = state[inst]       ---> struct vec *
		end, gen[self])
	end

	return gen[self]
end

function soa_mapper_mt.__index:map_var(name)
	local field = self.refct:member(name)
	if not field then return end

	local create
	if type(self.inst) == "cdata" then
		local ptr = ffi.cast("uint8_t *", self.inst) + field.offset  ---> &inst->band
		create = function()
			return driver.refk(ptr, 0)      ---> *ptr
		end
	else
		local offset = field.offset
		create = function(gen)
			return driver.refx(self:ref_gen(gen), offset, 0)       ---> *(*udata + offset)
		end
	end

	return conv.fromctype(field.type.element_type), create
end

function soa_mapper_mt.__index:shape_func()
	if type(self.inst) == "cdata" then
		local inst = ffi.cast("struct vec *", self.inst)
		return function()
			return inst.n_used
		end
	else
		local inst = self.inst
		return function(state)
			return ffi.cast("struct vec *", state[inst]).n_used
		end
	end
end

-- aux mappings --------------------

local fixed_mapper_mt = { __index={} }

local function fixed_size(size)
	return setmetatable({
		shapef = function() return size end
	}, fixed_mapper_mt)
end

function fixed_mapper_mt.__index:map_var(name)
end

function fixed_mapper_mt.__index:shape_func()
	return self.shapef
end

-- virtual mapper --------------------

---- edges ----------------------------------------

local function groupof(name)
	return name:match("^(.-)#.*$")
end

local function match_edges(rules)
	local rt = {}

	for i,rule in ipairs(rules) do
		local r,f = rule[1], rule[2]
		local from, to = r:match("^(.-)=>(.-)$")
		from = from == "" and "^(.*)$" or ("^" .. from .. "$")
		to = to == "" and "^(.*)$" or ("^" .. to .. "$")

		rt[i] = function(model, vname)
			local mg = {groupof(model.name):match(from)}
			if #mg == 0 then return end

			if not groupof(vname):match(to:gsub("(%%%d+)",
				function(j) return mg[tonumber(j:sub(2))] end)) then
				return
			end

			return f(model, vname)
		end
	end

	return function(model, vname, subset)
		if subset then return end
		for _,f in ipairs(rt) do
			local op, set, create = f(model, vname)
			if op then
				return op, set, create
			end
		end
	end
end

local function space() return C.FHK_MAP_SPACE, true end
local function only() return C.FHK_MAP_SPACE, false end
local function ident() return C.FHK_MAP_IDENT, false end

local builtin_maps = {
	all   = space,
	only  = only,
	ident = ident
}

local function builtin_map_edge(_, _, subset)
	local m = builtin_maps[subset]
	if m then return m() end
end

--------------------------------------------------------------------------------

return {
	parallel_group   = pgroup,
	struct_mapper    = struct_mapper,
	soa_mapper       = soa_mapper,
	fixed_size       = fixed_size,
	match_edges      = match_edges,
	space            = space,
	only             = only,
	ident            = ident,
	builtin_map_edge = builtin_map_edge
}