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
		if m.map_var then
			local t,c = m:map_var(lname)

			if t then
				if mapper then
					error(string.format("Mapping conflict: '%s' (originally '%s') is claimed by"
					.. " multiple mappers: %s and %s", lname, name, mapper, m))
				end

				mapper, typ, create = m, t, c
			end
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
		-- allow empty group as a special case to claim names
		return function() return 0 end
	end

	local funs = {}
	for i,m in ipairs(self.mappers) do
		if m.shape_func then
			table.insert(funs, m:shape_func(...))
		end
	end

	if #funs == 0 then
		error(string.format("%s: Non-empty group (%d) without shape function", self, #self.mappers))
	end

	if #funs == 1 then
		return funs[1]
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

function struct_mapper_mt.__index:ref_umem(umem)
	if not umem[self] then
		local inst = self.inst
		umem[self] = umem:scalar(ffi.typeof("void *"), function(state)
			return state[inst]       ---> ctype *
		end)
	end

	return umem[self]
end

function struct_mapper_mt.__index:map_var(name)
	local field = self.refct:member(name)
	if not field then return end

	local create
	if type(self.inst) == "cdata" then
		local ptr = ffi.cast("uint8_t *", self.inst) + field.offset
		create = function(dv)
			dv:set_vrefk(ptr)  ---> ptr
		end
	else
		local offset = field.offset
		create = function(dv, umem)
			local field = self:ref_umem(umem)
			umem:on_ctype(function(ctype)
				dv:set_vrefu(ffi.offsetof(ctype, field), offset)   ---> *udata + offset
			end)
		end
	end

	return conv.fromctype(field.type), create
end

local function shape1() return 1 end
function struct_mapper_mt.__index:shape_func()
	return shape1
end

-- plain array mapper --------------------
-- TODO TESTS

local array_mapper_mt = { __index={} }

local function array_mapper(objs)
	return setmetatable({objs = objs}, array_mapper_mt)
end

function array_mapper_mt.__index:ref_umem(umem, name)
	-- this could technically be called multiple times if multiple variables resolve
	-- to the same name (think aliases etc.)

	if not umem[self] then
		umem[self] = {}
	end

	if not umem[self][name] then
		umem[self][name] = umem:scalar(ffi.typeof("void *", function(state)
			return state[name]    ---> obj *
		end))
	end

	return gen[self][name]
end

function array_mapper_mt.__index:map_var(name)
	local obj = self.objs[name]
	if not obj then return end

	local ct = ffi.typeof(obj)
	local refct = reflect.typeof(ct)
	local create

	if type(obj) ~= "cdata" or obj == ct then -- it's a type
		create = function(dv, umem)
			local field = self:ref_umem(umem, name)
			umem:on_ctype(function(ctype)
				dv:set_vrefu(ffi.offset(ctype, field))     ---> udata
			end)
		end
	else -- it's cdata
		refct = refct.element_type
		create = function(dv)
			dv:set_vrefk(ffi.cast("void *", obj))       ---> obj
		end
	end

	return conv.fromctype(refct), create
end

-- vec mapper --------------------

local soa_mapper_mt = { __index={} }

local function soa_mapper(ctype, inst)
	return setmetatable({
		refct = reflect.typeof(ctype),
		inst  = inst
	}, soa_mapper_mt)
end

function soa_mapper_mt.__index:ref_umem(umem)
	if not umem[self] then
		local inst = self.inst
		umem[self] = umem:scalar(ffi.typeof("void *"), function(state)
			return state[inst]   ---> struct vec *
		end)
	end

	return umem[self]
end

function soa_mapper_mt.__index:map_var(name)
	local field = self.refct:member(name)
	if not field then return end

	local create
	if type(self.inst) == "cdata" then
		local ptr = ffi.cast("uint8_t *", self.inst) + field.offset  ---> &inst->band
		create = function(dv)
			dv:set_vrefk(ptr, 0)     ---> *ptr
		end
	else
		local offset = field.offset
		create = function(dv, umem)
			local field = self:ref_umem(umem)
			umem:on_ctype(function(ctype)
				dv:set_vrefu(ffi.offsetof(ctype, field), offset, 0) ---> *(*udata + offset)
			end)
		end
	end

	return conv.fromctype(field.type.element_type), create
end

local soa_ctp = ffi.typeof("struct vec *")
function soa_mapper_mt.__index:shape_func()
	if type(self.inst) == "cdata" then
		local inst = ffi.cast(soa_ctp, self.inst)
		return function()
			return inst.n_used
		end
	else
		local inst = self.inst
		return function(state)
			return ffi.cast(soa_ctp, state[inst]).n_used
		end
	end
end

-- aux mappings --------------------

-- fixed mapper: does nothing but provides a shape
local fixed_mapper_mt = { __index={} }

local function fixed_size(size)
	return setmetatable({
		shapef = function() return size end
	}, fixed_mapper_mt)
end

function fixed_mapper_mt.__index:shape_func()
	return self.shapef
end

-- translate mapper: proxies a mapper with different names, useful for mappers with name
-- restrictions (ctype mappers) and generated code
local translate_mapper_mt = { __index={} }

local function translate_mapper(translate, mapper)
	local tf = type(translate) == "table"
		and function(name) return translate[name] end
		or translate
	
	return setmetatable({
		translate = tf,
		mapper    = mapper
	}, translate_mapper_mt)
end

function translate_mapper_mt.__index:shape_func(...)
	return self.mapper:shape_func(...)
end

function translate_mapper_mt.__index:map_model(name)
	name = self.translate(name)
	if name then
		return self.mapper:map_model(name)
	end
end

function translate_mapper_mt.__index:map_var(name)
	name = self.translate(name)
	if name then
		return self.mapper:map_var(name)
	end
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

local function space() return C.FHKM_SPACE, true end
local function only() return C.FHKM_SPACE, false end
local function ident() return C.FHKM_IDENT, false end

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
	array_mapper     = array_mapper,
	soa_mapper       = soa_mapper,
	fixed_size       = fixed_size,
	translate_mapper = translate_mapper,
	groupof          = groupof,
	match_edges      = match_edges,
	space            = space,
	only             = only,
	ident            = ident,
	builtin_maps     = builtin_maps,
	builtin_map_edge = builtin_map_edge
}
