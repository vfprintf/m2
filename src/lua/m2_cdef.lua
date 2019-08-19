-- Autogenerated file - don't touch
local ffi = require 'ffi'
ffi.cdef [[
       
       
       
       
       
typedef uint8_t bm8 __attribute__((aligned(16)));
bm8 *bm_alloc(size_t n);
void bm_free(bm8 *bm);
void bm_set64(bm8 *bm, size_t n, uint64_t c);
void bm_zero(bm8 *bm, size_t n);
void bm_copy(bm8 *restrict a, const bm8 *restrict b, size_t n);
void bm_and64(bm8 *bm, size_t n, uint64_t mask);
void bm_or64(bm8 *bm, size_t n, uint64_t mask);
void bm_xor64(bm8 *bm, size_t n, uint64_t mask);
void bm_and(bm8 *restrict a, const bm8 *restrict b, size_t n);
void bm_or(bm8 *restrict a, const bm8 *restrict b, size_t n);
void bm_xor(bm8 *restrict a, const bm8 *restrict b, size_t n);
void bm_not(bm8 *bm, size_t n);
void bs_zero(bm8 *bs, size_t n);
unsigned bs_get(bm8 *bs, size_t idx);
void bs_set(bm8 *bs, size_t idx);
void bs_clear(bm8 *bs, size_t idx);
uint64_t bmask8(uint8_t mask8);
uint64_t bmask16(uint16_t mask16);
uint64_t bmask32(uint32_t mask32);
typedef uint64_t gridpos;
typedef uint32_t gridcoord;
struct grid {
 size_t order;
 size_t stride;
 void *data;
};
struct bitgrid {
 size_t order;
 bm8 *bs;
};
size_t grid_data_size(size_t order, size_t stride);
void grid_init(struct grid *g, size_t order, size_t stride, void *data);
void *grid_data(struct grid *g, gridpos z);
gridpos grid_max(size_t order);
gridpos grid_pos(gridcoord x, gridcoord y);
gridpos grid_zoom_up(gridpos z, size_t from, size_t to);
gridpos grid_zoom_down(gridpos z, size_t from, size_t to);
gridpos grid_translate_mask(size_t from, size_t to);
typedef enum type {
 T_F32 = 0,
 T_F64 = 1,
 T_B8 = 2,
 T_B16 = 3,
 T_B32 = 4,
 T_B64 = 5,
 T_POSITION = 6,
 T_USERDATA = 7
} type;
typedef union tvalue {
 float f32;
 double f64;
 uint8_t b8;
 uint16_t b16;
 uint32_t b32;
 uint64_t b64;
 gridpos z;
 void *u;
} tvalue;
typedef enum ptype {
 PT_REAL = 1,
 PT_BIT = 2,
 PT_POS = 3,
 PT_UDATA = 4
} ptype;
typedef union pvalue {
 double r;
 uint64_t b;
 gridpos z;
 void *u;
} pvalue;


typedef unsigned lexid;
struct var_def {
 lexid id;
 const char *name;
 type type;
};
struct obj_def {
 lexid id;
 const char *name;
 size_t resolution;
 struct { size_t nalloc; size_t nuse; struct var_def *data; } vars;
};
struct env_def {
 lexid id;
 const char *name;
 size_t resolution;
 type type;
};
struct lex {
 struct { size_t nalloc; size_t nuse; struct obj_def *data; } objs;
 struct { size_t nalloc; size_t nuse; struct env_def *data; } envs;
};
struct lex *lex_create();
void lex_destroy(struct lex *lex);
struct obj_def *lex_add_obj(struct lex *lex);
struct env_def *lex_add_env(struct lex *lex);
struct var_def *lex_add_var(struct obj_def *obj);
int unpackenum(uint64_t b);
uint64_t packenum(int b);
type tfitenum(unsigned max);
size_t tsize(type t);
ptype tpromote(type t);
pvalue vpromote(tvalue v, type t);
tvalue vdemote(pvalue v, type t);
void vcopy(void *dest, tvalue v, type t);
tvalue vbroadcast(tvalue v, type t);
uint64_t broadcast64(uint64_t x, unsigned b);
       
typedef struct sim sim;
typedef uint64_t sim_branchid;
typedef enum sim_mem {
 SIM_ALLOC_STATIC = 0,
 SIM_ALLOC_VSTACK = 1,
 SIM_ALLOC_FRAME = 2
} sim_mem;
sim *sim_create();
void sim_destroy(sim *sim);
void *sim_static_alloc(sim *sim, size_t sz, size_t align);
void *sim_vstack_alloc(sim *sim, size_t sz, size_t align);
void *sim_frame_alloc(sim *sim, size_t sz, size_t align);
void *sim_alloc(sim *sim, size_t sz, size_t align, sim_mem where);
int sim_is_frame_owned(sim *sim, void *p);
unsigned sim_frame_id(sim *sim);
void sim_savepoint(sim *sim);
void sim_restore(sim *sim);
void sim_enter(sim *sim);
void sim_exit(sim *sim);
sim_branchid sim_branch(sim *sim, size_t n, sim_branchid *branches);
sim_branchid sim_next_branch(sim *sim);
       
typedef struct world world;
typedef struct w_env {
 unsigned type : 32;
 unsigned zoom_order : 32;
 gridpos zoom_mask;
 struct grid grid;
} w_env;
typedef struct w_global {
 type type;
 tvalue value;
} w_global;
typedef struct w_vband {
 unsigned stride_bits : 16;
 unsigned type : 16;
 unsigned last_modify : 32;
 void *data;
} w_vband;
typedef struct w_objvec {
 unsigned n_alloc;
 unsigned n_used;
 unsigned n_bands;
 w_vband bands[];
} w_objvec;
typedef struct w_obj {
 int z_band;
 size_t vsize;
 w_objvec vtemplate;
} w_obj;
typedef struct w_objgrid {
 w_obj *obj;
 struct grid grid;
} w_objgrid;
typedef struct w_objref {
 w_objvec *vec;
 size_t idx;
} w_objref;
typedef struct w_objtpl {
 tvalue defaults[0];
} w_objtpl;
world *w_create(sim *sim);
void w_destroy(world *w);
w_env *w_define_env(world *w, type type, size_t resolution);
w_global *w_define_global(world *w, type type);
w_obj *w_define_obj(world *w, size_t nv, type *vtypes);
w_objgrid *w_define_objgrid(world *w, w_obj *obj, size_t order);
void w_env_swap(world *w, w_env *e, void *data);
size_t w_env_orderz(w_env *e);
gridpos w_env_posz(w_env *e, gridpos pos);
tvalue w_env_readpos(w_env *e, gridpos pos);
void w_obj_swap(world *w, w_objvec *vec, lexid varid, void *data);
void *w_vb_varp(w_vband *band, size_t idx);
void w_vb_vcopy(w_vband *band, size_t idx, tvalue v);
void *w_stride_varp(void *data, unsigned stride_bits, size_t idx);
tvalue w_obj_read1(w_objref *ref, lexid varid);
void w_obj_write1(w_objref *ref, lexid varid, tvalue value);
size_t w_tpl_size(w_obj *obj);
void w_tpl_create(w_obj *obj, w_objtpl *tpl);
void *w_env_create_data(world *w, w_env *e);
w_objvec *w_obj_create_vec(world *w, w_obj *obj);
size_t w_objvec_alloc(world *w, w_objvec *vec, w_objtpl *tpl, size_t n);
size_t w_objvec_delete(world *w, w_objvec *vec, size_t n, size_t *del);
size_t w_objvec_delete_s(world *w, w_objvec *vec, size_t n, size_t *del);
void *w_objvec_create_band(world *w, w_objvec *vec, lexid varid);
void w_objgrid_alloc(world *w, w_objref *refs, w_objgrid *g, w_objtpl *tpl, size_t n,
  gridpos *pos);
void w_objgrid_alloc_s(world *w, w_objref *refs, w_objgrid *g, w_objtpl *tpl, size_t n,
  gridpos *pos);
void w_objref_delete(world *w, size_t n, w_objref *refs);
void w_objref_delete_s(world *w, size_t n, w_objref *refs);
gridpos w_objgrid_posz(w_objgrid *g, gridpos pos);
w_objvec *w_objgrid_write(world *w, w_objgrid *g, gridpos z);
       
       
typedef struct arena arena;
typedef struct arena_ptr {
 void *chunk;
 void *ptr;
} arena_ptr;
arena *arena_create(size_t size);
void arena_destroy(arena *arena);
void arena_reset(arena *arena);
void *arena_alloc(arena *arena, size_t size, size_t align);
void *arena_malloc(arena *arena, size_t size);
char *arena_salloc(arena *arena, size_t size);
void arena_save(arena *arena, arena_ptr *p);
void arena_restore(arena *arena, arena_ptr *p);
int arena_contains(arena *arena, void *p);
char *arena_vasprintf(arena *arena, const char *fmt, va_list arg);
char *arena_asprintf(arena *arena, const char *fmt, ...);
char *arena_strcpy(arena *arena, const char *src);
enum fhk_ctype {
 FHK_RIVAL,
 FHK_BITSET
};
struct fhk_rival {
 double min;
 double max;
};
struct fhk_cst {
 enum fhk_ctype type;
 union {
  struct fhk_rival rival;
  uint64_t setmask;
 };
};
struct fhk_space {
 struct fhk_cst cst;
};
enum {
 FHK_COST_OUT = 0,
 FHK_COST_IN = 1
};
struct fhk_check {
 struct fhk_var *var;
 struct fhk_cst cst;
 double costs[2];
};
struct fhk_model {
 unsigned idx;
 double k, c;
 size_t n_check;
 struct fhk_check *checks;
 size_t n_param;
 struct fhk_var **params;
 pvalue *returns;
 double min_cost, max_cost;
 void *udata;
};
struct fhk_var {
 unsigned idx;
 size_t n_mod;
 struct fhk_model **models;
 pvalue **mret;
 pvalue value;
 unsigned select_model;
 double min_cost, max_cost;
 void *udata;
};
typedef union fhk_mbmap { uint8_t u8; struct { unsigned blacklisted : 1; unsigned has_bound : 1; unsigned chain_selected : 1; unsigned has_return : 1; unsigned may_fail : 1; } __attribute__((packed));  } fhk_mbmap;
typedef union fhk_vbmap { uint8_t u8; struct { unsigned given : 1; unsigned solve : 1; unsigned solving : 1; unsigned chain_selected : 1; unsigned has_value : 1; unsigned has_bound : 1; unsigned stable : 1; } __attribute__((packed));  } fhk_vbmap;
enum {
 FHK_NOT_RESOLVED = -1,
 FHK_OK = 0,
 FHK_RESOLVE_FAILED = 1,
 FHK_MODEL_FAILED = 2,
 FHK_CYCLE = 3,
 FHK_REQUIRED_UNSOLVABLE = 4
};
struct fhk_einfo {
 int err;
 struct fhk_model *model;
 struct fhk_var *var;
};
typedef struct fhk_graph fhk_graph;
typedef int (*fhk_model_exec)(fhk_graph *G, void *udata, pvalue *ret, pvalue *args);
typedef int (*fhk_var_resolve)(fhk_graph *G, void *udata, pvalue *value);
typedef void (*fhk_chain_solved)(fhk_graph *G, void *udata, pvalue value);
typedef const char *(*fhk_desc)(void *udata);
struct fhk_graph {
 fhk_model_exec exec_model;
 fhk_var_resolve resolve_var;
 fhk_chain_solved chain_solved;
 fhk_desc debug_desc_var;
 fhk_desc debug_desc_model;
 size_t n_var;
 struct fhk_var *vars;
 fhk_vbmap *v_bitmaps;
 size_t n_mod;
 struct fhk_model *models;
 fhk_mbmap *m_bitmaps;
 struct fhk_einfo last_error;
 void *udata;
};
void fhk_reset(struct fhk_graph *G, fhk_vbmap vmask, fhk_mbmap mmask);
void fhk_supp(bm8 *vmask, bm8 *mmask, struct fhk_var *y);
void fhk_inv_supp(struct fhk_graph *G, bm8 *vmask, bm8 *mmask);
int fhk_solve(struct fhk_graph *G, struct fhk_var *y);
struct fhk_graph *fhk_alloc_graph(arena *arena, size_t n_var, size_t n_mod);
void fhk_alloc_checks(arena *arena, struct fhk_model *m, size_t n_check, struct fhk_check *checks);
void fhk_alloc_params(arena *arena, struct fhk_model *m, size_t n_param, struct fhk_var **params);
void fhk_alloc_returns(arena *arena, struct fhk_model *m, size_t n_ret);
void fhk_alloc_models(arena *arena, struct fhk_var *x, size_t n_mod, struct fhk_model **models);
void fhk_link_ret(struct fhk_model *m, struct fhk_var *x, size_t mind, size_t xind);
struct fhk_var *fhk_get_var(struct fhk_graph *G, unsigned idx);
struct fhk_model *fhk_get_model(struct fhk_graph *G, unsigned idx);
struct fhk_model *fhk_get_select(struct fhk_var *x);
       
typedef struct ex_func ex_func;
int ex_exec(ex_func *f, pvalue *ret, pvalue *argv);
void ex_destroy(ex_func *f);
ex_func *ex_R_create(const char *fname, const char *func, int narg, ptype *argt, int nret,
  ptype *rett);
ex_func *ex_simoC_create(const char *libname, const char *func, int narg, ptype *argt, int nret,
  ptype *rett);
       
typedef struct ugraph ugraph;
typedef struct u_obj u_obj;
typedef struct u_var u_var;
typedef struct u_env u_env;
typedef struct u_comp u_comp;
typedef struct u_global u_global;
typedef struct u_model u_model;
typedef void (*u_solver_cb)(void *udata, struct fhk_graph *G, size_t nv, struct fhk_var **xs);
ugraph *u_create(struct fhk_graph *G);
void u_destroy(ugraph *u);
u_obj *u_add_obj(ugraph *u, w_obj *obj, const char *name);
u_var *u_add_var(ugraph *u, u_obj *obj, lexid varid, struct fhk_var *x, const char *name);
u_env *u_add_env(ugraph *u, w_env *env, struct fhk_var *x, const char *name);
u_global *u_add_global(ugraph *u, w_global *glob, struct fhk_var *x, const char *name);
u_comp *u_add_comp(ugraph *u, struct fhk_var *x, const char *name);
u_model *u_add_model(ugraph *u, ex_func *f, struct fhk_model *m, const char *name);
void u_init_given_obj(bm8 *init_v, u_obj *obj);
void u_init_given_envs(bm8 *init_v, ugraph *u);
void u_init_given_globals(bm8 *init_v, ugraph *u);
void u_init_solve(bm8 *init_v, struct fhk_var *y);
void u_graph_init(ugraph *u, bm8 *init_v);
void u_mark_obj(bm8 *vmask, u_obj *obj);
void u_mark_envs_z(bm8 *vmask, ugraph *u, size_t order);
void u_reset_mark(ugraph *u, bm8 *vmask, bm8 *mmask);
void u_graph_reset(ugraph *u, bm8 *reset_v, bm8 *reset_m);
void u_bind_obj(u_obj *obj, w_objref *ref);
void u_unbind_obj(u_obj *obj);
void u_bind_pos(ugraph *u, gridpos pos);
void u_unbind_pos(ugraph *u);
void u_solve_vec(ugraph *u, u_obj *obj, bm8 *reset_v, bm8 *reset_m, w_objvec *v,
  size_t nv, struct fhk_var **xs, void **res, type *types);
void u_update_vec(ugraph *u, u_obj *obj, world *w, bm8 *reset_v, bm8 *reset_m, w_objvec *v,
  size_t nv, struct fhk_var **xs, lexid *vars);
       
typedef float vf32 __attribute__((aligned(16)));
typedef double vf64 __attribute__((aligned(16)));
void vset_f64(vf64 *d, double c, size_t n);
void vadd_f64s(vf64 *d, vf64 *a, double c, size_t n);
void vadd_f64v(vf64 *d, vf64 *a, const vf64 *restrict b, size_t n);
]]
