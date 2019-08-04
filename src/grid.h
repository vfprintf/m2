#pragma once

#include "bitmap.h"

#include <stdlib.h>
#include <stdint.h>

typedef uint64_t gridpos;
typedef uint32_t gridcoord;

/* A square 2D grid with 2^{order} pixels in each dimension stored as a Z-order curve,
 * where order=2*k for some k */
struct grid {
	size_t order;
	size_t stride;
	void *data;
};

struct bitgrid {
	size_t order;
	bm8 *bs;
};

#define GRID_ORDER(k) ((k)<<1)
size_t grid_data_size(size_t order, size_t stride);
void grid_init(struct grid *g, size_t order, size_t stride, void *data);
void *grid_data(struct grid *g, gridpos z);

gridpos grid_max(size_t order);
gridpos grid_pos(gridcoord x, gridcoord y);
gridpos grid_zoom_up(gridpos z, size_t from, size_t to);
gridpos grid_zoom_down(gridpos z, size_t from, size_t to);
gridpos grid_translate_mask(size_t from, size_t to);