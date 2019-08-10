local ffi = require "ffi"
local conf = require "conf"
local exec = require "exec"
local typing = require "typing"

ffi.cdef [[
	struct Lvar_info {
		const char *desc;
		const char *kind;
		type type;
	};

	struct Lmodel_info {
		const char *desc;
		ex_func *f;
	};
]]

-------------------------

local function varinfo(udata)
	return ffi.cast("struct Lvar_info *", udata)
end

local function modelinfo(udata)
	return ffi.cast("struct Lmodel_info *", udata)
end

local function hook_graph(G)
	G.model_exec = function(G, udata, ret, args)
		return exec.exec(modelinfo(udata).f, ret, args)
	end

	G.resolve_virtual = function(G, udata, value)
		assert(false)
	end

	G.debug_desc_var = function(udata)
		return varinfo(udata).desc
	end

	G.debug_desc_model = function(udata)
		return modelinfo(udata).desc
	end
end

local function hook_udata(data)
	for _,fv in pairs(data.fhk_vars) do
		local info = ffi.new("struct Lvar_info")
		info.desc = fv.src.name
		info.type = fv.src.type
		info.kind = fv.kind
		fv.info = info
		fv.fhk_var.udata = info
	end

	for _,fm in pairs(data.fhk_models) do
		local info = ffi.new("struct Lmodel_info")
		info.desc = fm.name
		info.f = fm.ex_func
		fm.info = info
		fm.fhk_model.udata = info
	end
end

local function init_graph(G, data)
	for _,fv in pairs(data.fhk_vars) do
		fv.fhk_var.is_virtual = 0
	end

	ffi.C.fhk_reset(G, ffi.C.FHK_RESET_ALL)
end

local function get_vars(data, names)
	local fv = data.fhk_vars
	local ret = {}
	for _,n in ipairs(names) do
		table.insert(ret, fv[n])
	end
	return ret
end

local function set_flag(G, vars, flag)
	local bitmap = ffi.new("fhk_vbmap")
	bitmap.u8 = 0
	bitmap[flag] = 1

	for _,v in ipairs(vars) do
		local idx = v.fhk_var.idx
		G.v_bitmaps[idx].u8 = bit.bor(G.v_bitmaps[idx].u8, bitmap.u8)
	end
end

-------------------------

local function reportv(visited, ret, G, fv, reason)
	local idx = tonumber(fv.idx)

	if visited[idx] then
		return
	end

	visited[idx] = true

	local fvinfo = varinfo(fv.udata)
	local bitmap = G.v_bitmaps[fv.idx]

	local r = {
		value  = typing.sim2out(typing.pvalue2lua(fv.mark.value, fvinfo.type), fvinfo.type),
		desc   = ffi.string(fvinfo.desc),
		reason = reason,
		kind   = ffi.string(fvinfo.kind),
		given  = bitmap.given == 1,
		solved = bitmap.chain_selected == 1
	}

	table.insert(ret, r)

	if r.given then
		r.cost = 0
	end

	if r.solved and (not r.given) then
		local fm = fv.mark.model
		local fminfo = modelinfo(fm.udata)
		r.model = ffi.string(fminfo.desc)
		r.cost = fv.mark.min_cost

		for i=0, tonumber(fm.n_param)-1 do
			reportv(visited, ret, G, fm.params[i], "parameter")
		end

		for i=0, tonumber(fm.n_check)-1 do
			reportv(visited, ret, G, fm.checks[i].var, "constraint")
		end
	end
end

local function report(G, vars)
	local visited = {}
	local ret = {}

	for _,v in ipairs(vars) do
		reportv(visited, ret, G, v.fhk_var, "root")
	end

	return ret
end

local function print_report(rep)
	print(string.format("%-20s   %-20s %-20s %-16s %s",
		"Variable",
		"Value",
		"Model",
		"Cost",
		"Status"
	))

	for _,r in ipairs(rep) do
		print(string.format("%-20s = %-20s %-20s %-16f %s %s (%s)",
			r.desc,
			r.value,
			r.model or "",
			r.cost  or "",
			r.given and "given" or (r.solved and "solved" or "failed"),
			r.reason,
			r.kind
		))
	end
end

-------------------------

local function readcsv(fname)
	local f = io.open(fname)
	local header = map(split(f:read()), trim)
	local data = {}

	for l in f:lines() do
		local d = map(split(l), tonumber)
		if #d ~= #header then
			error(string.format("Invalid line: %s (expected %d values but have %d)",
				l, #d, #header))
		end
		table.insert(data, d)
	end

	f:close()

	return header, data
end

-------------------------

local function main(args)
	local data = conf.read(get_builtin_file("builtin_lex.lua"), args.config)
	local G = conf.create_fhk_graph(data)
	hook_udata(data)
	init_graph(G, data)
	hook_graph(G)

	local vars, values = readcsv(args.input)
	vars = get_vars(data, vars)
	local solve = get_vars(data, args.vars)
	set_flag(G, vars, "given")
	set_flag(G, solve, "solve")

	for _,d in ipairs(values) do
		for i,v in ipairs(vars) do
			v.fhk_var.mark.value = typing.lua2pvalue(typing.out2sim(d[i], v.src.type), v.src.type)

		end

		ffi.C.fhk_reset(G, 0)

		for _,v in ipairs(solve) do
			ffi.C.fhk_solve(G, v.fhk_var)
		end

		print("--------------------")
		local rep = report(G, solve)
		print_report(rep)
	end
end

return {
	main = main
}