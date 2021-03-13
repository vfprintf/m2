#pragma once

// fhk shared internal definitions

#include "fhk.h"

#include <stdint.h>
#include <assert.h>

typedef struct {
	fhk_idx idx;
	uint8_t a, b;
	fhk_map map;
} fhk_edge;

typedef struct {
	float penalty;
	fhk_map map;
	fhk_idx idx;
	uint8_t flags;
	// uint8_t unused
} fhk_shedge;

static_assert(sizeof(fhk_edge) == sizeof(uint64_t));

// shadows:             shadows [p_shadow, 0)
// computed parameters: params  [0, p_cparam)            a: original edge idx
// given parameters:    params  [p_cparam, p_param)      a: original edge idx
// returns:             returns [0, p_return)            a: original edge idx
#define FHK_MODEL_BW          \
	union { fhk_edge *params; fhk_shedge *shadows; }; \
	fhk_grp group;            \
	int8_t p_shadow;          \
	uint8_t p_cparam;         \
    uint8_t p_param;          \
	uint8_t p_return;         \
	uint8_t flags;            \
	/* uint8_t unused */      \
	float k, c

struct fhk_model {
	FHK_MODEL_BW;              // must be first
	float ki, ci;
	float cmin;
	// uint32_t unused
	fhk_edge *returns;
};

struct fhk_var {
	fhk_edge *models;          // a: inverse edge index
	fhk_edge *fwds;
	fhk_grp group;
	uint16_t size;
	uint16_t n_fwd;
	uint8_t n_mod;
};

struct fhk_shadow {
	fhk_shvalue arg;
	fhk_grp group;
	fhk_idx xi;
	uint8_t flags;
	uint8_t guard;
	uint64_t unused;
};

static_assert(sizeof(struct fhk_var) == sizeof(struct fhk_shadow));

struct fhk_graph {
	struct fhk_model models[0];

	fhk_nidx nv; // variable count
	fhk_nidx nx; // variable-like count (variables+shadows)
	fhk_nidx nm; // model count
	fhk_nidx nu; // user map count
	fhk_grp ng;  // group count

#if FHK_DEBUG
	const char **dsym; // this is only meant for debugging fhk itself - not your graph
#endif

	union {
		struct fhk_shadow shadows[0];
		struct fhk_var vars[0];
	};
};

// model flags
#define M_NORETBUF 0x1

// shadow flags
#define W_COMPUTED 0x1

#define ISVI(xi) ((xi) >= 0)
#define ISMI(mi) ((mi) < 0)

// variable is given <==> no models
// note: use this only for debugging (eg asserts).
//       for graph algorithms use the edge ordering.
#define V_GIVEN(x)    ((x)->n_mod == 0)
#define V_COMPUTED(x) (!V_GIVEN(x))

// graph size
#define G_GRPBITS    14       /* bits per group size */
#define G_MAXGRP     0x3fff   /* max valid group */
#define G_IDXBITS    15       /* bits per index (var/model) */
#define G_MAXIDX     0x7ffe   /* max valid (positive) index */
#define G_INSTBITS   16       /* bits per instance */
#define G_MAXINST    0xfffe   /* max valid instance */
#define G_EDGEBITS   8        /* bits per edge count */
#define G_MAXEDGE    0x7f     /* max (positive) edge */
#define G_MAXFWDE    0xffff   /* max v->m forward edge (n_fwd) */
#define G_MAXMODE    0xff     /* max v->m backward edge (n_mod) */
#define G_UMAPBITS   8        /* bits per user mapping */
#define G_MAXUMAP    0xfe     /* max valid user mapping */

static_assert(8*sizeof(fhk_grp) >= G_GRPBITS);
static_assert(8*sizeof(fhk_idx) >= G_IDXBITS);
static_assert((1<<8*sizeof(fhk_inst)) > G_MAXINST);
static_assert(8*sizeof(fhk_map) >= G_UMAPBITS);

// internal map representation.
// note: P_* macros are only for internal maps!!
//
//           +----+----+---------+-------+------+
//           | 31 | 30 | 30..16  | 16..9 | 8..0 |
// +---------+----+----+---------+-------+------+
// | user    | 1  | 0  | group-> |   0   | uref |
// +---------+----+----+---------+-------+------+
// | space   | 0  | 0  |    0    |   ->group    |
// +---------+----+----+---------+---------+----+
// | ident   |  1............................1  |
// +---------+----------------------------------+
#define P_ISIDENT(map)      ((int32_t)(map) == -1)
#define P_ISSPACE(map)      ((int32_t)(map) >= 0)
#define P_ISUSER(map)       ((int32_t)(map) < -1)
#define P_UREF              0x0000ffff
#define P_UINV              0x00000001
#define P_UIDX(map)         (((map) & 0xffff) >> 1)
#define P_UGROUP(map)       (((map) >> 16) & 0x7fff)
#define P_IDENT             0xffffffff
#define P_SPACE(group)      (group)
#define P_UMAP(group,num)   (0x80000000 | ((group)<<16) | ((num)<<1))
#define P_UMAPI(group,num)  ((P_UMAP(group,num)) | 1)

// error handling
#define E_META(n,f,x)       ((FHKEI_##f << (4*((n)+1))) | ((uint64_t)(x) << (16*(n))))

typedef uint32_t xgrp;   // group
typedef int32_t  xidx;   // index
typedef uint32_t xinst;  // instance
typedef uint32_t xmap;   // mapping
typedef uint32_t xuref;  // usermap

#define min(a, b) ({ typeof(a) _a = (a); typeof(b) _b = (b); _a < _b ? _a : _b; })
#define max(a, b) ({ typeof(a) _a = (a); typeof(b) _b = (b); _a > _b ? _a : _b; })
#define costf(m, S) ({ struct fhk_model *_m = (m); _m->k + _m->c*(S); })
#define costf_invS(m, cost) ({ struct fhk_model *_m = (m); _m->ki + _m->ci*(cost); })

#if FHK_DEBUG
const char *fhk_dsym(struct fhk_graph *G, xidx idx);
#endif
