local alloc = require "alloc"
local code = require "code"
local ffi = require "ffi"
local C = ffi.C

-- memcmp needed for vector/bitmap equality testing
ffi.cdef [[ int memcmp ( const void *, const void *, size_t); ]]

-- small vector math library, design goals:
-- * integrate well with simulator, eg. do allocations from sim memory
-- * as little gc load as possible (this caused problem with the old implementation)
-- * try not to make traces too long (no complicated metatable tricks, this also caused problems
--   with the old implementation)
--
-- two ways to call the functions are offered:
--
-- * procedural-style:
--     vmath.mul(trees.ba, trees.f, #trees)
--     vmath.mul(trees.ba, 1/10000, #trees)
--
-- * oop-style:
--     local ba = vmath.real(trees.ba, #trees)
--     ba:mul(trees.f)
--     ba:mul(1/10000)

local sizeof_double = ffi.sizeof("double")

--------------------------------------------------------------------------------

local function vecstr(data, n)
	local s = {}
	for i=0, tonumber(n)-1 do
		local sf = string.format("%010f", tonumber(data[i]))
		table.insert(s, sf)
	end
	return table.concat(s, "  ")
end

-- No need to check for double (or float) here, they will be "converted" to numbers before this
local function isscalar(x)
	return type(x) == "number"
end

local function overload2(scalarf, vectorf)
	return function(x, p, n, d)
		d = d or x
		if isscalar(p) then
			scalarf(d, x, p, n)
		else
			vectorf(d, x, p, n)
		end
	end
end

local function vdsubc(d, x, c, n) C.vdaddc(d, x, -c, n) end
local function vdsubv(d, x, y, n) C.vdaddsv(d, x, -1, y, n) end

local vmath_f = {
	double = {
		set      = C.vdsetc,
		add      = overload2(C.vdaddc, C.vdaddv),
		sub      = overload2(vdsubc, vdsubv),
		saddc    = function(x, a, b, n, d) C.vdaddsc(d or x, a, x, b, n) end,
		adds     = function(x, a, y, n, d) C.vdaddsv(d or x, x, a, y, n) end,
		mul      = overload2(C.vdscale, C.vdmulv),
		refl     = function(x, a, y, n, d) C.vdrefl(d or x, a, x, y, n) end,
		area     = function(x, n, d) C.vdaread(d, x, n) end,
		sum      = C.vdsum,
		summ8    = C.vdsumm8,
		dot      = C.vddot,
		avgw     = C.vdavgw,
		copy     = function(dest, src, n) ffi.copy(dest, src, n*sizeof_double) end,
		tostring = vecstr,
	}
}

--------------------------------------------------------------------------------

local function todatad(x)
	return ffi.istype("double *", x) and x or x.data
end

local function overload2vd(scalarf, vectorf)
	return function(self, p, d)
		d = d and todatad(d) or self.data

		if isscalar(p) then
			scalarf(d, self.data, p, self.n)
		else
			vectorf(d, self.data, todata(p), self.n)
		end
	end
end

local vecm8d_ct = ffi.metatype([[
	struct {
		double *data;
		uint8_t *k;
		uint64_t mask;
		size_t n;
	}]], {
	
	__index = {
		sum   = function(self) return (C.vsumm8(self.data, self.k, self.mask, self.n)) end
	}
})

local vecd_ct = ffi.metatype([[
	struct {
		double *data;
		size_t n;
	}]], {

	__index = {
		set   = function(self, c) C.vdsetc(self.data, c, self.n) end,
		add   = overload2vd(C.vdaddc, C.vdaddv),
		sub   = overload2vd(vdsubc, vdsubv),
		saddc = function(self, a, b, d)
			vmath_f.double.saddc(self.data, a, b, self.n, d and todatad(d))
		end,
		adds  = function(self, a, y, d)
			vmath_f.double.adds(self.data, a, todatad(y), self.n, d and todatad(d))
		end,
		mul   = overload2vd(C.vdscale, C.vdmulv),
		refl  = function(self, a, y, d)
			vmath_f.double.refl(self.data, a, todatad(y), self.n, d and todatad(d))
		end,
		area  = function(self, d) C.vdaread(self.data, todatad(d), self.n) end,
		sum   = function(self) return (C.vdsum(self.data, self.n)) end,
		dot   = function(self, y) return (C.vddot(self.data, todatad(y), self.n)) end,
		avgw  = function(self, w) return (C.vdavgw(self.data, todatad(w), self.n)) end,
		mask  = function(self, mask, m) return (vecm_ct(self.data, mask, m, self.n)) end
	},

	__tostring = function(self) return vecstr(self.data, self.n) end,
	__len = function(self) return tonumber(self.n) end,
	__eq = function(self, other)
		return C.memcmp(self.data, todata(other), self.n*sizeof_double) ~= 0
	end
})

vmath_f.double.vec = vec_ct
vmath_f.double.vecm8 = vecm_ct

--------------------------------------------------------------------------------

local function freevec(v)
	C.free(v.data)
end

local function allocvecd(n)
	local data = alloc.malloc_nogc("double", n)
	return ffi.gc(vecd_ct(data, n), freevec)
end

--------------------------------------------------------------------------------

local loop_mt = { __index={} }

local function defloop(n, wrap)
	local vnames = {}
	local vidx = {}

	for i=1, n do
		vnames[i] = "___v"..i
		vidx[i] = (wrap and vnames[i]..".data" or vnames[i]).."[___i]"
	end

	vnames = table.concat(vnames, ",")
	vidx = table.concat(vidx, ",")

	return function(loop)
		return string.format([[
			function(%s, %s ___state)
				%s
				for ___i=0, %s do
					%s
				end
				%s
			end
		]], vnames, wrap and "" or "n,",
		loop.preloop(),
		wrap and "#___v1-1" or "n-1",
		loop.body(vidx .. ", ___state"), loop.postloop())
	end
end

local function loop(loopfunc, ...)
	if type(loopfunc) == "number" then
		loopfunc = defloop(loopfunc, ...)
	end

	return setmetatable({
		loopfunc  = loopfunc,
		value     = "%s",
		code      = code.new(),
		upvalues  = {},
	}, loop_mt)
end

function loop_mt.__index:map(f)
	local name = "___map"..#self.code
	self.code:emitf("local %s = %s", name, name)
	self.upvalues[name] = f
	self.value = string.format("%s(%s)", name, self.value)
	return self
end

function loop_mt.__index:reduce(f, ...)
	local name = "___reduce"..#self.code
	self.code:emitf("local %s = %s", name, name)
	self.upvalues[name] = f

	local init = {...}
	local rvs = {}
	for i,v in ipairs(init) do
		local ivname = "___reduce_init"..i
		self.code:emitf("local %s = %s", ivname, ivname)
		self.upvalues[ivname] = v
		table.insert(rvs, "___r"..i)
	end

	rvs = table.concat(rvs, ", ")

	self.code:emitf("return %s", self.loopfunc {

		preloop = function()
			local ret = {}
			for i=1, #rvs do
				table.insert(ret, string.format("local ___r%d = ___reduce_init%d", i, i))
			end
			return table.concat(ret, "\n")
		end,

		body = function(iv)
			iv = string.format(self.value, iv)
			return string.format("%s = %s(%s, %s)", rvs, name, rvs, iv)
		end,

		postloop = function()
			return string.format("return  %s", rvs)
		end

	})

	return self:compile()
end

function loop_mt.__index:sum()
	return self:reduce(function(a, b) return a+b end, 0)
end

function loop_mt.__index:dot2()
	return self:reduce(function(r, a, b) return r+a*b end, 0)
end

function loop_mt.__index:compile()
	return self.code:compile(self.upvalues, string.format("=(loop@%p)", self))()
end

--------------------------------------------------------------------------------

local function inject(env)
	local _sim = env.m2.sim

	env.m2.vmath = setmetatable({
		loop    = loop,

		-- Note: maybe add a function to alloc from sim pool instead if malloc is too slow
		allocvd = allocvecd
		-- allocbitmap?
	}, { __index = vmath_f })
end

return {
	vmath_f   = vmath_f,
	allocvec  = allocvec,
	inject    = inject
}
