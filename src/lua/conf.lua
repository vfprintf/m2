local typing = require "typing"
local exec = require "exec"
local fhk = require "fhk"
local ffi = require "ffi"
local C = ffi.C

local function newconf()
	local conf_env = get_builtin_file("conf_env.lua")
	local env, data = dofile(conf_env)
	return env, data
end

local function resolve_dt(xs)
	for _,x in pairs(xs) do
		local dtype = x.type
		if not typing.builtin_types[dtype] then
			error(string.format("No definition found for type '%s' of '%s'",
				dtype, x.name))
		end

		x.type = typing.builtin_types[dtype]
		
		-- TODO: non-builtins
	end
end

local function resolve_types(data)
	resolve_dt(data.envs)
	resolve_dt(data.vars)
	for _,o in pairs(data.objs) do
		resolve_dt(o.vars)
	end
end

local function link_graph(data)
	local fhk_vars = setmetatable({}, {__index=function(self,k)
		self[k] = { models={} }
		return self[k]
	end})

	for _,o in pairs(data.objs) do
		for _,v in pairs(o.vars) do
			fhk_vars[v.name].src = v
			fhk_vars[v.name].kind = "var"
		end
	end

	for _,e in pairs(data.envs) do
		fhk_vars[e.name].src = e
		fhk_vars[e.name].kind = "env"
	end

	for _,v in pairs(data.vars) do
		fhk_vars[v.name].src = v
		fhk_vars[v.name].kind = "computed"
	end

	setmetatable(fhk_vars, nil)

	for _,m in pairs(data.fhk_models) do
		for i,p in ipairs(m.params) do
			local fv = fhk_vars[p]
			if not fv then
				error(string.format("No definition found for var '%s' (parameter of model '%s')",
					p, m.name))
			end

			m.params[i] = fv
			-- delete named version, only used for dupe checking in conf_env
			m.params[p] = nil
		end

		for i,c in ipairs(m.checks) do
			local fv = fhk_vars[c.var]
			if not fv then
				error(string.format("No definition found for var '%s' (constraint of model '%s')",
					c.var, m.name))
			end

			c.var = fv
		end

		local rv = fhk_vars[m.returns]
		if not rv then
			error(string.format("No definition found for var '%s' (return value of model '%s')",
				m.returns, m.name))
		end

		m.returns = rv
		table.insert(rv.models, m)
	end

	data.fhk_vars = fhk_vars
end

local function verify_names(data)
	local _used = {}
	local used = setmetatable({}, {__newindex=function(_, k, v)
		if _used[k] then
			error(string.format("Duplicate definition of name '%s'", k))
		end
		_used[k] = v
	end})

	for _,o in pairs(data.objs) do
		used[o.name] = true
		for _,v in pairs(o.vars) do
			used[v.name] = true
		end
	end

	for _,e in pairs(data.envs) do
		used[e.name] = true
	end

	for _,v in pairs(data.vars) do
		used[v.name] = true
	end
end

local function verify_models(data)
	for _,m in pairs(data.fhk_models) do
		if not m.impl then
			error(string.format("Missing impl for model '%s'", m.name))
		end
	end
end

local function read(...)
	local env, data = newconf()

	local fnames = {...}
	for _,f in ipairs(fnames) do
		env.read(f)
	end

	resolve_types(data)
	link_graph(data)
	verify_names(data)
	verify_models(data)

	return data
end

local function create_lexicon(data)
	local arena = C.arena_create(1024)
	local lex = ffi.gc(C.lex_create(), function(lex)
		C.arena_destroy(arena)
		C.lex_destroy(lex)
	end)

	for _,o in pairs(data.objs) do
		local lo = C.lex_add_obj(lex)
		o.lexobj = lo
		lo.name = arena_copystring(arena, o.name)
		lo.resolution = o.resolution

		for _,v in pairs(o.vars) do
			local lv = C.lex_add_var(lo)
			v.lexvar = lv
			lv.name = arena_copystring(arena, v.name)
			lv.type = v.type
		end
	end

	for _,e in pairs(data.envs) do
		local le = C.lex_add_env(lex)
		e.lexenv = le
		le.name = arena_copystring(arena, e.name)
		le.resolution = e.resolution
		le.type = e.type
	end

	data.lex = lex
	return lex
end

local function create_fhk_graph(data)
	local arena = C.arena_create(4096)

	local models = collect(data.fhk_models)
	local vars = collect(data.fhk_vars)
	local n_models = #models
	local n_vars = #vars

	local c_models = ffi.cast("struct fhk_model *", C.arena_malloc(arena,
		ffi.sizeof("struct fhk_model[?]", n_models)))
	local c_vars = ffi.cast("struct fhk_var *", C.arena_malloc(arena,
		ffi.sizeof("struct fhk_var[?]", n_vars)))

	for i=0, n_models-1 do
		models[i+1].fhk_model = c_models+i
		models[i+1].ex_func = exec.from_model(models[i+1])
		c_models[i].idx = i
	end

	for i=0, n_vars-1 do
		vars[i+1].fhk_var = c_vars+i
		c_vars[i].idx = i
	end

	local G = ffi.gc(C.arena_malloc(arena, ffi.sizeof("struct fhk_graph")), function()
		C.arena_destroy(arena)
	end)

	G = ffi.cast("struct fhk_graph *", G)
	G.n_var = n_vars
	G.n_mod = n_models

	C.fhk_graph_init(G)

	fhk.init_fhk_graph(G, data, function(sz) return C.arena_malloc(arena, sz) end)

	return G
end

return {
	read=read,
	create_lexicon=create_lexicon,
	create_fhk_graph=create_fhk_graph
}
