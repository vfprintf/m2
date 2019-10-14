local ffi = require "ffi"
local models = require "model"
local typing = require "typing"
local alloc = require "alloc"
local C = ffi.C
local band = bit.band

local function copy_cst(check, cst)
	if cst.type == "interval" then
		check.type = C.FHK_RIVAL
		check.rival.min = cst.a
		check.rival.max = cst.b
	elseif cst.type == "set" then
		check.type = C.FHK_BITSET
		check.setmask = cst.mask
	else
		error(string.format("invalid cst type '%s'", cst.type))
	end
end

local function create_checks(checks, sv)
	local vars, cs = {}, {}
	for name,cst in pairs(checks) do
		table.insert(vars, sv[name])
		table.insert(cs, cst)
	end

	if #cs == 0 then
		return nil, 0
	end

	local ret = ffi.new("struct fhk_check[?]", #cs)

	for i=0, #cs-1 do
		local c = ret+i
		local cst = cs[i+1]
		local var = vars[i+1]
		c.var = var.fhk_var
		c.costs[C.FHK_COST_IN] = cst.cost_in
		c.costs[C.FHK_COST_OUT] = cst.cost_out
		copy_cst(c.cst, cst)
	end

	return ret, #cs
end

local function copyvars(dest, vars, sv)
	for i,name in ipairs(vars) do
		dest[i-1] = sv[name].fhk_var
	end

	return dest
end

local function copy_graph(vars, models)
	local sv, sm = {}, {}
	local nv, nm = 0, 0

	for name,def in pairs(models) do
		sm[name] = { src=def }

		for _,p in ipairs(def.params) do
			sv[p] = true
		end

		for v,_ in pairs(def.checks) do
			sv[v] = true
		end

		for _,r in ipairs(def.returns) do
			sv[r] = true
		end

		nm = nm + 1
	end

	for name,_ in pairs(sv) do
		if not vars[name] then
			error(string.format("Missing definition for var '%s'", name))
		end
		sv[name] = { type=vars[name].type }
		nv = nv + 1
	end

	return sv, sm, nv, nm
end

local function assign_ptrs(G, sv, sm)
	local nv, nm = 0, 0

	for _,m in pairs(sm) do
		m.fhk_model = C.fhk_get_model(G, nm)
		nm = nm+1
	end

	for _,v in pairs(sv) do
		v.fhk_var = C.fhk_get_var(G, nv)
		nv = nv+1
	end
end

local function build_models(G, arena, sv, sm)
	for _,m in pairs(sm) do
		local fm = m.fhk_model

		fm.k = m.src.k or 1
		fm.c = m.src.c or 1

		if not m.src.k or not m.src.c then
			io.stderr:write(string.format("warn: No cost given for model %s - defaulting to 1\n",
				m.src.name))
		end

		local checks, ncheck = create_checks(m.src.checks, sv)
		C.fhk_copy_checks(arena, fm, ncheck, checks)

		local params = copyvars(ffi.new("struct fhk_var *[?]", #m.src.params), m.src.params, sv)
		C.fhk_copy_params(arena, fm, #m.src.params, params)

		local returns = copyvars(ffi.new("struct fhk_var *[?]", #m.src.returns), m.src.returns, sv)
		C.fhk_copy_returns(arena, fm, #m.src.returns, returns)
	end
end

local function build_graph(vars, models)
	local sv, sm, nv, nm = copy_graph(vars, models)
	local arena = alloc.arena_nogc()
	local G = ffi.gc(C.fhk_alloc_graph(arena, nv, nm), function() C.arena_destroy(arena) end)
	assign_ptrs(G, sv, sm)
	build_models(G, arena, sv, sm)
	C.fhk_compute_links(arena, G)
	return G, sv, sm
end

local function create_models(sv, sm, calib)
	calib = calib or {}
	local ret = {}
	local conf = models.config()

	for name,model in pairs(sm) do
		conf:reset()
		local atypes = conf:newatypes(#model.src.params)
		local rtypes = conf:newrtypes(#model.src.returns)
		for i,n in ipairs(model.src.params) do atypes[i-1] = typing.promote(sv[n].type.desc) end
		for i,n in ipairs(model.src.returns) do rtypes[i-1] = typing.promote(sv[n].type.desc) end
		conf.n_coef = #model.src.coeffs
		conf.calibrated = calib[name]

		local def = models.def(model.src.impl.lang, model.src.impl.opt):configure(conf)

		local mod = def()
		ret[name] = mod

		local cal = calib[name]
		if cal then
			for i,c in ipairs(model.src.coeffs) do
				if not cal[c] then
					error(string.format("Missing coefficient '%s' for model '%s'", c, name))
				end

				mod.coefs[i-1] = cal[c]
			end
			mod:calibrate()
		end
	end

	return ret
end

local graph_mt = { __index = {
	vmask = function(self)
		local ret = ffi.gc(C.bm_alloc(self.n_var), C.bm_free)
		C.bm_zero(ret, self.n_var)
		return ret
	end,

	init  = C.gmap_init,
	reset = C.fhk_reset_mask
}}

ffi.metatype("struct fhk_graph", graph_mt)

--------------------------------------------------------------------------------

local binder_mt = { __call = function(self, ...) return self.bind(...) end }

local function binder(ctype)
	local b = alloc.malloc(ctype)
	return setmetatable({
		bind = function(v)
			b[0] = v
		end,
		ref  = b+0
	}, binder_mt)
end

local bind = {
	z   = function() return binder("gridpos") end,
	vec = function() return binder("struct vec_ref") end
}

local function bind_ns(b)
	return setmetatable({}, {__index=function(self, k)
		self[k] = b()
		return self[k]
	end})
end

local mapper_mt = { __index = {} }

local function hook(G, vars, models)
	C.gmap_hook(G)

	local mapper = setmetatable({
		G        = G,
		vars     = vars,
		models   = models,
		virtuals = {},
		bind     = {
			z   = bind_ns(bind.z),
			vec = bind_ns(bind.vec)
		}
	}, mapper_mt)

	if C.HAVE_SOLVER_INTERRUPTS == 1 then
		mapper.gs_ctx = ffi.gc(C.gs_create_ctx(), C.gs_destroy_ctx)
	end

	return mapper
end

function mapper_mt.__index:bind_mapping(mapping, name)
	local v = self.vars[name]
	if not v then
		error(string.format("Can't bind mapping '%s': there is no such variable", name))
	end
	if v.mapping then
		error(string.format("Variable '%s' already has this mapping -> %s", name, v.mapping))
	end
	-- name is a table key of mapper so it will not be gc'd thanks to interning
	-- (meaning we don't need to copy it over, this pointer will work)
	mapping.name = name
	mapping.target_type = v.type.desc
	C.gmap_bind(self.G, v.fhk_var.idx, ffi.cast("struct gmap_any *", mapping))
	v.mapping = mapping
	return mapping
end

function mapper_mt.__index:vec(name, offset, band, bind)
	local ret = alloc.malloc("struct gv_vec")
	ret.resolve = C.gmap_res_vec
	ret.target_offset = offset
	ret.target_band = band
	ret.bind = bind
	return self:bind_mapping(ret, name)
end

function mapper_mt.__index:grid(name, offset, grid, bind)
	local ret = alloc.malloc("struct gv_grid")
	ret.resolve = C.gmap_res_grid
	ret.target_offset = offset
	ret.grid = grid
	ret.bind = bind
	return self:bind_mapping(ret, name)
end

function mapper_mt.__index:data(name, ref)
	local ret = alloc.malloc("struct gv_data")
	ret.resolve = C.gmap_res_data
	ret.ref = ref
	return self:bind_mapping(ret, name)
end

if C.HAVE_SOLVER_INTERRUPTS == 1 then
	function mapper_mt.__index:virtual(name, func)
		local ret = alloc.malloc("struct gs_virt")
		ret.resolve = C.gs_res_virt
		ret.handle = #self.virtuals + 1
		self.virtuals[#self.virtuals + 1] = self:wrap_virtual(name, func)
		return self:bind_mapping(ret, name)
	end
else
	function mapper_mt.__index:virtual()
		error("No virtual support -- compile with SOLVER_INTERRUPTS=on")
	end
end

function mapper_mt.__index:wrap_virtual(name, func)
	local ptype = typing.promote(self.vars[name].type.desc)
	local tname = typing.desc_builtin[tonumber(ptype)].tname

	return function()
		local ret = ffi.new("pvalue")
		ret[tname] = func()
		return ret.u64 -- see comment in mapper:solver_res()
	end
end

function mapper_mt.__index:bind_computed()
	for name,v in pairs(self.vars) do
		if not v.mapping then
			local map = alloc.malloc("struct gmap_any")
			map.resolve = nil
			map.supp = nil
			self:bind_mapping(map, name)
		end
	end
end

function mapper_mt.__index:mapping(name, ctype)
	local ret = self.vars[name].udata
	if ctype then
		ret = ffi.cast(ctype .. "*", ret)
	end
	return ret
end

function mapper_mt.__index:bind_model(name, mod)
	local model = self.models[name]
	assert(not model.mapping)
	local ret = alloc.malloc("struct gmap_model")
	ret.name = name
	ret.mod = mod
	C.gmap_bind_model(self.G, model.fhk_model.idx, ret)
	model.mapping = ret
	model.mapping_mod = mod
	return ret
end

function mapper_mt.__index:create_models(calib)
	local exf = create_models(self.vars, self.models, calib)
	for name,f in pairs(exf) do
		self:bind_model(name, f)
	end
end

if C.HAVE_SOLVER_INTERRUPTS == 1 then
	-- the actual signature is gs_res (*)(pvalue) - we cast to avoid unsupported conversions
	-- (pvalue is an aggregate).
	local resume = ffi.cast("gs_res (*)(uint64_t)", C.gs_resume)

	function mapper_mt.__index:enter_solver()
		C.gs_enter(self.gs_ctx)
	end

	function mapper_mt.__index:solver_res(r)
		r = tonumber(r)
		while band(r, C.GS_RETURN) == 0 do
			assert(band(r, C.GS_INTERRUPT_VIRT) ~= 0)
			local virt = self.virtuals[band(r, C.GS_ARG_MASK)]
			-- virt() must return uint64_t here!
			r = tonumber(resume(virt()))
		end

		if band(r, C.GS_ARG_MASK) ~= C.FHK_OK then
			self:failed()
		end
	end
else
	function mapper_mt.__index:enter_solver() end

	function mapper_mt.__index:solver_res(r)
		assert(band(r, C.GS_RETURN) ~= 0)

		if band(r, C.GS_ARG_MASK) ~= C.FHK_OK then
			self:failed()
		end
	end
end

function mapper_mt.__index:c_solver(names)
	local ret = ffi.gc(ffi.new("struct fhk_solver"), C.fhk_solver_destroy)
	C.fhk_solver_init(ret, self.G, #names)

	for i,name in ipairs(names) do
		local v = self.vars[name]
		ret.xs[i-1] = v.fhk_var
	end

	return ret
end

function mapper_mt.__index:mark_visible(vmask, reason, parm)
	C.gmap_mark_visible(self.G, vmask, reason, parm)
end

function mapper_mt.__index:mark_nonconstant(vmask, reason, parm)
	C.gmap_mark_nonconstant(self.G, vmask, reason, parm)
end

function mapper_mt.__index:mark(vmask, names, mark)
	mark = mark or 0xff

	for _,name in ipairs(names) do
		local fv = self.vars[name]
		vmask[fv.fhk_var.idx] = mark
	end
end

function mapper_mt.__index:set_init_vmask(vmask, names)
	local G = self.G

	local given = ffi.new("fhk_vbmap")
	given.given = 1
	C.bm_and64(vmask, G.n_var, C.bmask8(given.u8))

	-- clear given bit for targets
	self:mark(vmask, names, 0)
end

function mapper_mt.__index:failed()
	local fv = self.G.last_error.var
	local fm = self.G.last_error.model
	local var, model

	if fv ~= ffi.NULL then
		for name,v in pairs(self.vars) do
			if ffi.cast("void *", v.mapping) == fv.udata then
				var = name
				break
			end
		end
	end

	if fm ~= ffi.NULL then
		for name,m in pairs(self.models) do
			if ffi.cast("void *", m.mapping) == fm.udata then
				model = name
				break
			end
		end
	end

	local context = {"fhk: solver failed"}

	if var then
		table.insert(context, string.format("\t* Caused by this variable: %s", var))
	end

	if model then
		table.insert(context, string.format("\t* Caused by this model: %s", model))
	end

	local err = self.G.last_error.err
	if err == ffi.C.FHK_MODEL_FAILED then
		table.insert(context, "Model crashed (details below):")
		table.insert(context, models.error())
	else
		table.insert(context, string.format("\t* The error code was: %d", err))
	end

	error(table.concat(context, "\n"))
end


local solver_func_mt = { __index = {} }

local function solver_make_res(names, vs)
	local ret = {}
	for i,name in pairs(names) do
		local ptype = typing.promote(vs[name].type.desc)
		ret[name] = {
			idx = i-1,
			ctype = typing.desc_builtin[tonumber(ptype)].ctype .. "*"
		}
	end
	return ret
end

function mapper_mt.__index:solver(names)
	return setmetatable({
		mapper   = self,
		solver   = self:c_solver(names),
		init_v   = self.G:vmask(),
		names    = names,
		res_info = solver_make_res(names, self.vars)
	}, solver_func_mt)
end

function solver_func_mt.__index:from(src)
	src:mark_visible(self.mapper, self.init_v)
	src:mark_nonconstant(self.mapper, self.solver.reset_v)
	self.mapper:set_init_vmask(self.init_v, self.names)
	self.mapper:mark(self.solver.reset_v, self.names)
	self.solver:make_reset_masks()

	local solver_func = src:solver_func(self.mapper, self.solver)
	self.solve = function(...)
		self.mapper.G:init(self.init_v)
		self.mapper:enter_solver()
		local r = solver_func(...)
		self.mapper:solver_res(r)
	end

	return self
end

function solver_func_mt.__index:res(name)
	local info = self.res_info[name]
	return (ffi.cast(info.ctype, self.solver.res[info.idx]))
end

function solver_func_mt:__call(...)
	return self.solve(...)
end

local solver_mt = { __index = {
	make_reset_masks = function(self)
		C.gmap_make_reset_masks(self.G, self.reset_v, self.reset_m)
	end,

	bind = C.fhk_solver_bind,
	step = C.fhk_solver_step
}}

ffi.metatype("struct fhk_solver", solver_mt)

local function cast_any(f)
	return function(self, ...)
		return f(ffi.cast("struct gmap_any *", self), ...)
	end
end

local support = {
	var    = cast_any(C.gmap_supp_obj_var),
	env    = cast_any(C.gmap_supp_grid_env),
	global = cast_any(C.gmap_supp_global)
}

--------------------------------------------------------------------------------

local rebind = function(sim, solver, n)
	local res_size = n * ffi.sizeof("pvalue")

	for i=0, tonumber(solver.nv)-1 do
		local res = C.sim_alloc(sim, res_size, ffi.alignof("pvalue"), C.SIM_FRAME)
		solver:bind(i, res)
	end
end

local function inject(env, mapper)
	env.fhk = {
		solve   = function(...) return mapper:solver({...}) end,
		bind    = function(x, ...) x:bind(mapper, ...) end,
		expose  = function(x) x:expose(mapper) end,
		typeof  = function(x) return mapper.vars[x].type end,
		virtual = function(name, x, f) return x:virtualize(mapper, name, f) end
	}

	env.on("sim:compile", function()
		mapper:bind_computed()
	end)
end

return {
	build_graph     = build_graph,
	create_models   = create_models,
	hook            = hook,
	bind            = bind,
	support         = support,
	inject          = inject,
	rebind          = rebind
}
