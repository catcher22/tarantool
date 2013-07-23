
#line 1 "admin.rl"
/*
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <stdlib.h>

#include <fiber.h>
#include <palloc.h>
#include <salloc.h>
#include <say.h>
#include <stat.h>
#include <tarantool.h>
#include "lua/init.h"
#include <recovery.h>
#include <tbuf.h>
#include "tarantool/util.h"
#include <errinj.h>
#include "coio_buf.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include "box/box.h"
#include "lua/init.h"
#include "session.h"
#include "scoped_guard.h"

static const char *help =
	"available commands:" CRLF
	" - help" CRLF
	" - exit" CRLF
	" - show info" CRLF
	" - show fiber" CRLF
	" - show configuration" CRLF
	" - show slab" CRLF
	" - show palloc" CRLF
	" - show stat" CRLF
	" - show plugins" CRLF
	" - save coredump" CRLF
	" - save snapshot" CRLF
	" - lua command" CRLF
	" - reload configuration" CRLF
	" - show injections (debug mode only)" CRLF
	" - set injection <name> <state> (debug mode only)" CRLF;

static const char *unknown_command = "unknown command. try typing help." CRLF;


#line 83 "admin.cc"
static const char _admin_actions[] = {
	0, 1, 0, 1, 1, 1, 2, 1, 
	3, 1, 5, 1, 6, 1, 8, 1, 
	10, 1, 11, 1, 14, 1, 15, 1, 
	16, 1, 17, 1, 18, 1, 19, 1, 
	20, 1, 21, 2, 9, 4, 2, 12, 
	7, 2, 13, 7
};

static const short _admin_key_offsets[] = {
	0, 0, 7, 8, 10, 12, 13, 16, 
	17, 20, 22, 24, 26, 27, 30, 33, 
	36, 38, 41, 44, 47, 49, 50, 52, 
	55, 57, 60, 61, 64, 65, 67, 69, 
	70, 73, 76, 79, 82, 85, 88, 91, 
	94, 97, 100, 103, 105, 107, 109, 111, 
	112, 115, 117, 120, 121, 124, 127, 130, 
	133, 136, 139, 141, 142, 145, 148, 151, 
	154, 157, 160, 162, 164, 165, 167, 169, 
	170, 171, 173, 176, 179, 181, 183, 186, 
	188, 190, 192, 194, 196, 198, 200, 201, 
	202, 204, 210, 211, 214, 217, 220, 223, 
	226, 229, 232, 235, 238, 241, 244, 246, 
	247, 250, 253, 256, 258, 259, 263, 266, 
	268, 271, 274, 277, 280, 283, 286, 289, 
	291, 293, 296, 299, 302, 305, 307, 310, 
	313, 316, 319, 322, 324, 326, 329, 332, 
	334, 337, 340, 342, 344, 345
};

static const char _admin_trans_keys[] = {
	99, 101, 104, 108, 113, 114, 115, 104, 
	32, 101, 32, 115, 108, 10, 13, 97, 
	10, 10, 13, 98, 10, 13, 32, 99, 
	32, 107, 32, 10, 13, 120, 10, 13, 
	105, 10, 13, 116, 10, 13, 10, 13, 
	101, 10, 13, 108, 10, 13, 112, 10, 
	13, 117, 32, 97, 10, 13, 32, 10, 
	13, 10, 13, 32, 32, 10, 13, 117, 
	101, 32, 108, 32, 99, 111, 10, 13, 
	110, 10, 13, 102, 10, 13, 105, 10, 
	13, 103, 10, 13, 117, 10, 13, 114, 
	10, 13, 97, 10, 13, 116, 10, 13, 
	105, 10, 13, 111, 10, 13, 110, 10, 
	13, 32, 111, 32, 97, 32, 100, 32, 
	97, 101, 104, 32, 118, 32, 99, 115, 
	111, 10, 13, 114, 10, 13, 101, 10, 
	13, 100, 10, 13, 117, 10, 13, 109, 
	10, 13, 112, 10, 13, 110, 10, 13, 
	97, 10, 13, 112, 10, 13, 115, 10, 
	13, 104, 10, 13, 111, 10, 13, 116, 
	10, 13, 32, 101, 32, 32, 116, 32, 
	105, 110, 106, 32, 101, 32, 33, 126, 
	32, 33, 126, 32, 111, 102, 110, 10, 
	13, 102, 10, 13, 10, 13, 32, 99, 
	32, 116, 32, 105, 32, 111, 32, 110, 
	32, 32, 32, 111, 32, 99, 102, 105, 
	112, 115, 111, 10, 13, 110, 10, 13, 
	102, 10, 13, 105, 10, 13, 103, 10, 
	13, 117, 10, 13, 114, 10, 13, 97, 
	10, 13, 116, 10, 13, 105, 10, 13, 
	111, 10, 13, 110, 10, 13, 105, 10, 
	13, 98, 10, 13, 101, 10, 13, 114, 
	10, 13, 110, 10, 13, 102, 106, 10, 
	13, 111, 10, 13, 10, 13, 101, 10, 
	13, 99, 10, 13, 116, 10, 13, 105, 
	10, 13, 111, 10, 13, 110, 10, 13, 
	115, 10, 13, 97, 108, 10, 13, 108, 
	10, 13, 108, 10, 13, 111, 10, 13, 
	99, 10, 13, 10, 13, 117, 10, 13, 
	103, 10, 13, 105, 10, 13, 110, 10, 
	13, 115, 10, 13, 108, 116, 10, 13, 
	97, 10, 13, 98, 10, 13, 10, 13, 
	97, 10, 13, 116, 10, 13, 32, 119, 
	32, 0
};

static const char _admin_single_lengths[] = {
	0, 7, 1, 2, 2, 1, 3, 1, 
	3, 2, 2, 2, 1, 3, 3, 3, 
	2, 3, 3, 3, 2, 1, 2, 3, 
	2, 3, 1, 3, 1, 2, 2, 1, 
	3, 3, 3, 3, 3, 3, 3, 3, 
	3, 3, 3, 2, 2, 2, 2, 1, 
	3, 2, 3, 1, 3, 3, 3, 3, 
	3, 3, 2, 1, 3, 3, 3, 3, 
	3, 3, 2, 2, 1, 2, 2, 1, 
	1, 2, 1, 1, 2, 2, 3, 2, 
	2, 2, 2, 2, 2, 2, 1, 1, 
	2, 6, 1, 3, 3, 3, 3, 3, 
	3, 3, 3, 3, 3, 3, 2, 1, 
	3, 3, 3, 2, 1, 4, 3, 2, 
	3, 3, 3, 3, 3, 3, 3, 2, 
	2, 3, 3, 3, 3, 2, 3, 3, 
	3, 3, 3, 2, 2, 3, 3, 2, 
	3, 3, 2, 2, 1, 0
};

static const char _admin_range_lengths[] = {
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 1, 1, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0
};

static const short _admin_index_offsets[] = {
	0, 0, 8, 10, 13, 16, 18, 22, 
	24, 28, 31, 34, 37, 39, 43, 47, 
	51, 54, 58, 62, 66, 69, 71, 74, 
	78, 81, 85, 87, 91, 93, 96, 99, 
	101, 105, 109, 113, 117, 121, 125, 129, 
	133, 137, 141, 145, 148, 151, 154, 157, 
	159, 163, 166, 170, 172, 176, 180, 184, 
	188, 192, 196, 199, 201, 205, 209, 213, 
	217, 221, 225, 228, 231, 233, 236, 239, 
	241, 243, 246, 249, 252, 255, 258, 262, 
	265, 268, 271, 274, 277, 280, 283, 285, 
	287, 290, 297, 299, 303, 307, 311, 315, 
	319, 323, 327, 331, 335, 339, 343, 346, 
	348, 352, 356, 360, 363, 365, 370, 374, 
	377, 381, 385, 389, 393, 397, 401, 405, 
	408, 411, 415, 419, 423, 427, 430, 434, 
	438, 442, 446, 450, 453, 456, 460, 464, 
	467, 471, 475, 478, 481, 483
};

static const unsigned char _admin_indicies[] = {
	0, 2, 3, 4, 5, 6, 7, 1, 
	8, 1, 9, 10, 1, 9, 11, 1, 
	12, 1, 13, 14, 15, 1, 16, 1, 
	13, 14, 17, 1, 13, 14, 1, 9, 
	18, 1, 9, 19, 1, 9, 1, 20, 
	21, 22, 1, 20, 21, 23, 1, 20, 
	21, 24, 1, 20, 21, 1, 25, 26, 
	27, 1, 25, 26, 28, 1, 25, 26, 
	29, 1, 25, 26, 1, 30, 1, 31, 
	32, 1, 1, 1, 34, 33, 36, 37, 
	35, 36, 37, 34, 33, 31, 1, 20, 
	21, 22, 1, 38, 1, 39, 40, 1, 
	39, 41, 1, 42, 1, 43, 44, 45, 
	1, 43, 44, 46, 1, 43, 44, 47, 
	1, 43, 44, 48, 1, 43, 44, 49, 
	1, 43, 44, 50, 1, 43, 44, 51, 
	1, 43, 44, 52, 1, 43, 44, 53, 
	1, 43, 44, 54, 1, 43, 44, 55, 
	1, 43, 44, 1, 39, 56, 1, 39, 
	57, 1, 39, 58, 1, 39, 1, 59, 
	60, 61, 1, 62, 63, 1, 62, 64, 
	65, 1, 66, 1, 67, 68, 69, 1, 
	67, 68, 70, 1, 67, 68, 71, 1, 
	67, 68, 72, 1, 67, 68, 73, 1, 
	67, 68, 74, 1, 67, 68, 1, 75, 
	1, 76, 77, 78, 1, 76, 77, 79, 
	1, 76, 77, 80, 1, 76, 77, 81, 
	1, 76, 77, 82, 1, 76, 77, 83, 
	1, 76, 77, 1, 62, 84, 1, 62, 
	1, 85, 86, 1, 85, 87, 1, 88, 
	1, 89, 1, 90, 91, 1, 90, 92, 
	1, 93, 94, 1, 95, 96, 1, 97, 
	98, 1, 99, 100, 101, 1, 99, 100, 
	1, 102, 103, 1, 90, 104, 1, 90, 
	105, 1, 90, 106, 1, 90, 107, 1, 
	90, 108, 1, 90, 1, 85, 1, 109, 
	110, 1, 109, 111, 112, 113, 114, 115, 
	1, 116, 1, 117, 118, 119, 1, 117, 
	118, 120, 1, 117, 118, 121, 1, 117, 
	118, 122, 1, 117, 118, 123, 1, 117, 
	118, 124, 1, 117, 118, 125, 1, 117, 
	118, 126, 1, 117, 118, 127, 1, 117, 
	118, 128, 1, 117, 118, 129, 1, 117, 
	118, 1, 130, 1, 131, 132, 133, 1, 
	131, 132, 134, 1, 131, 132, 135, 1, 
	131, 132, 1, 136, 1, 137, 138, 139, 
	140, 1, 137, 138, 141, 1, 137, 138, 
	1, 142, 143, 144, 1, 142, 143, 145, 
	1, 142, 143, 146, 1, 142, 143, 147, 
	1, 142, 143, 148, 1, 142, 143, 149, 
	1, 142, 143, 150, 1, 142, 143, 1, 
	151, 152, 1, 153, 154, 155, 1, 153, 
	154, 156, 1, 153, 154, 157, 1, 153, 
	154, 158, 1, 153, 154, 1, 159, 160, 
	161, 1, 159, 160, 162, 1, 159, 160, 
	163, 1, 159, 160, 164, 1, 159, 160, 
	165, 1, 159, 160, 1, 166, 167, 1, 
	168, 169, 170, 1, 168, 169, 171, 1, 
	168, 169, 1, 172, 173, 174, 1, 172, 
	173, 175, 1, 172, 173, 1, 109, 176, 
	1, 109, 1, 1, 0
};

static const unsigned char _admin_trans_targs[] = {
	2, 0, 13, 17, 21, 27, 28, 48, 
	3, 4, 10, 5, 6, 141, 7, 8, 
	141, 9, 11, 12, 141, 7, 14, 15, 
	16, 141, 7, 18, 19, 20, 22, 23, 
	26, 24, 25, 24, 141, 7, 29, 30, 
	44, 31, 32, 141, 7, 33, 34, 35, 
	36, 37, 38, 39, 40, 41, 42, 43, 
	45, 46, 47, 49, 69, 88, 50, 67, 
	51, 59, 52, 141, 7, 53, 54, 55, 
	56, 57, 58, 60, 141, 7, 61, 62, 
	63, 64, 65, 66, 68, 70, 87, 71, 
	72, 73, 74, 81, 75, 76, 75, 76, 
	77, 78, 80, 141, 7, 79, 141, 7, 
	82, 83, 84, 85, 86, 89, 139, 90, 
	103, 108, 120, 132, 91, 141, 7, 92, 
	93, 94, 95, 96, 97, 98, 99, 100, 
	101, 102, 104, 141, 7, 105, 106, 107, 
	109, 141, 7, 110, 112, 111, 141, 7, 
	113, 114, 115, 116, 117, 118, 119, 121, 
	126, 141, 7, 122, 123, 124, 125, 141, 
	7, 127, 128, 129, 130, 131, 133, 136, 
	141, 7, 134, 135, 141, 7, 137, 138, 
	140
};

static const char _admin_trans_actions[] = {
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 33, 33, 0, 
	0, 0, 0, 0, 19, 19, 0, 0, 
	0, 7, 7, 0, 0, 0, 0, 0, 
	0, 13, 13, 0, 35, 35, 0, 0, 
	0, 0, 0, 9, 9, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 31, 31, 0, 0, 0, 
	0, 0, 0, 0, 11, 11, 0, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 15, 17, 0, 0, 
	0, 0, 0, 41, 41, 0, 38, 38, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 0, 0, 3, 3, 0, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 0, 0, 23, 23, 0, 0, 0, 
	0, 21, 21, 0, 0, 0, 5, 5, 
	0, 0, 0, 0, 0, 0, 0, 0, 
	0, 27, 27, 0, 0, 0, 0, 1, 
	1, 0, 0, 0, 0, 0, 0, 0, 
	25, 25, 0, 0, 29, 29, 0, 0, 
	0
};

static const int admin_start = 1;
static const int admin_first_final = 141;
static const int admin_error = 0;

static const int admin_en_main = 1;


#line 82 "admin.rl"


struct salloc_stat_admin_cb_ctx {
	int64_t total_used;
	struct tbuf *out;
};

static int
salloc_stat_admin_cb(const struct slab_cache_stats *cstat, void *cb_ctx)
{
	struct salloc_stat_admin_cb_ctx *ctx = (struct salloc_stat_admin_cb_ctx *) cb_ctx;

	tbuf_printf(ctx->out,
		    "     - { item_size: %- 5i, slabs: %- 3i, items: %- 11" PRIi64
		    ", bytes_used: %- 12" PRIi64
		    ", bytes_free: %- 12" PRIi64 " }" CRLF,
		    (int)cstat->item_size,
		    (int)cstat->slabs,
		    cstat->items,
		    cstat->bytes_used,
		    cstat->bytes_free);

	ctx->total_used += cstat->bytes_used;
	return 0;
}

static void
show_slab(struct tbuf *out)
{
	struct salloc_stat_admin_cb_ctx cb_ctx;
	struct slab_arena_stats astat;

	cb_ctx.total_used = 0;
	cb_ctx.out = out;

	tbuf_printf(out, "slab statistics:\n  classes:" CRLF);

	salloc_stat(salloc_stat_admin_cb, &astat, &cb_ctx);

	tbuf_printf(out, "  items_used: %.2f%%" CRLF,
		(double)cb_ctx.total_used / astat.size * 100);
	tbuf_printf(out, "  arena_used: %.2f%%" CRLF,
		(double)astat.used / astat.size * 100);
}

static void
end(struct tbuf *out)
{
	tbuf_printf(out, "..." CRLF);
}

static void
start(struct tbuf *out)
{
	tbuf_printf(out, "---" CRLF);
}

static void
ok(struct tbuf *out)
{
	start(out);
	tbuf_printf(out, "ok" CRLF);
	end(out);
}

static void
fail(struct tbuf *out, struct tbuf *err)
{
	start(out);
	tbuf_printf(out, "fail:%.*s" CRLF, err->size, (char *)err->data);
	end(out);
}

static void
tarantool_info(struct tbuf *out)
{
	tbuf_printf(out, "info:" CRLF);
	tbuf_printf(out, "  version: \"%s\"" CRLF, tarantool_version());
	tbuf_printf(out, "  uptime: %i" CRLF, (int)tarantool_uptime());
	tbuf_printf(out, "  pid: %i" CRLF, getpid());
	tbuf_printf(out, "  logger_pid: %i" CRLF, logger_pid);
	tbuf_printf(out, "  snapshot_pid: %i" CRLF, snapshot_pid);
	tbuf_printf(out, "  lsn: %" PRIi64 CRLF,
		    recovery_state->confirmed_lsn);
	tbuf_printf(out, "  recovery_lag: %.3f" CRLF,
		    recovery_state->remote ?
		    recovery_state->remote->recovery_lag : 0);
	tbuf_printf(out, "  recovery_last_update: %.3f" CRLF,
		    recovery_state->remote ?
		    recovery_state->remote->recovery_last_update_tstamp :0);
	box_info(out);
	const char *path = cfg_filename_fullpath;
	if (path == NULL)
		path = cfg_filename;
	tbuf_printf(out, "  config: \"%s\"" CRLF, path);
}

static int
show_stat_item(const char *name, int rps, int64_t total, void *ctx)
{
	struct tbuf *buf = (struct tbuf *) ctx;
	int name_len = strlen(name);
	tbuf_printf(buf,
		    "  %s:%*s{ rps: %- 6i, total: %- 12" PRIi64 " }" CRLF,
		    name, 1 + stat_max_name_len - name_len, " ", rps, total);
	return 0;
}

void
show_stat(struct tbuf *buf)
{
	tbuf_printf(buf, "statistics:" CRLF);
	stat_foreach(show_stat_item, buf);
}

static int
admin_dispatch(struct ev_io *coio, struct iobuf *iobuf, lua_State *L)
{
	struct ibuf *in = &iobuf->in;
	struct tbuf *out = tbuf_new(fiber->gc_pool);
	struct tbuf *err = tbuf_new(fiber->gc_pool);
	int cs;
	char *p, *pe;
	char *strstart, *strend;
	bool state;

	while ((pe = (char *) memchr(in->pos, '\n', in->end - in->pos)) == NULL) {
		if (coio_bread(coio, in, 1) <= 0)
			return -1;
	}

	pe++;
	p = in->pos;

	
#line 483 "admin.cc"
	{
	cs = admin_start;
	}

#line 488 "admin.cc"
	{
	int _klen;
	unsigned int _trans;
	const char *_acts;
	unsigned int _nacts;
	const char *_keys;

	if ( p == pe )
		goto _test_eof;
	if ( cs == 0 )
		goto _out;
_resume:
	_keys = _admin_trans_keys + _admin_key_offsets[cs];
	_trans = _admin_index_offsets[cs];

	_klen = _admin_single_lengths[cs];
	if ( _klen > 0 ) {
		const char *_lower = _keys;
		const char *_mid;
		const char *_upper = _keys + _klen - 1;
		while (1) {
			if ( _upper < _lower )
				break;

			_mid = _lower + ((_upper-_lower) >> 1);
			if ( (*p) < *_mid )
				_upper = _mid - 1;
			else if ( (*p) > *_mid )
				_lower = _mid + 1;
			else {
				_trans += (unsigned int)(_mid - _keys);
				goto _match;
			}
		}
		_keys += _klen;
		_trans += _klen;
	}

	_klen = _admin_range_lengths[cs];
	if ( _klen > 0 ) {
		const char *_lower = _keys;
		const char *_mid;
		const char *_upper = _keys + (_klen<<1) - 2;
		while (1) {
			if ( _upper < _lower )
				break;

			_mid = _lower + (((_upper-_lower) >> 1) & ~1);
			if ( (*p) < _mid[0] )
				_upper = _mid - 2;
			else if ( (*p) > _mid[1] )
				_lower = _mid + 2;
			else {
				_trans += (unsigned int)((_mid - _keys)>>1);
				goto _match;
			}
		}
		_trans += _klen;
	}

_match:
	_trans = _admin_indicies[_trans];
	cs = _admin_trans_targs[_trans];

	if ( _admin_trans_actions[_trans] == 0 )
		goto _again;

	_acts = _admin_actions + _admin_trans_actions[_trans];
	_nacts = (unsigned int) *_acts++;
	while ( _nacts-- > 0 )
	{
		switch ( *_acts++ )
		{
	case 0:
#line 217 "admin.rl"
	{
		    start(out);
                    show_plugins_stat(out);
		    end(out);
                }
	break;
	case 1:
#line 223 "admin.rl"
	{
			start(out);
			show_cfg(out);
			end(out);
		}
	break;
	case 2:
#line 229 "admin.rl"
	{
			start(out);
			errinj_info(out);
			end(out);
		}
	break;
	case 3:
#line 235 "admin.rl"
	{
			start(out);
			tbuf_append(out, help, strlen(help));
			end(out);
		}
	break;
	case 4:
#line 241 "admin.rl"
	{
			strstart[strend-strstart]='\0';
			start(out);
			tarantool_lua(L, out, strstart);
			end(out);
		}
	break;
	case 5:
#line 248 "admin.rl"
	{
			if (reload_cfg(err))
				fail(out, err);
			else
				ok(out);
		}
	break;
	case 6:
#line 255 "admin.rl"
	{
			int ret = snapshot();

			if (ret == 0)
				ok(out);
			else {
				tbuf_printf(err, " can't save snapshot, errno %d (%s)",
					    ret, strerror(ret));

				fail(out, err);
			}
		}
	break;
	case 7:
#line 268 "admin.rl"
	{
			strstart[strend-strstart] = '\0';
			if (errinj_set_byname(strstart, state)) {
				tbuf_printf(err, "can't find error injection '%s'", strstart);
				fail(out, err);
			} else {
				ok(out);
			}
		}
	break;
	case 8:
#line 295 "admin.rl"
	{strstart = p;}
	break;
	case 9:
#line 295 "admin.rl"
	{strend = p;}
	break;
	case 10:
#line 303 "admin.rl"
	{ strstart = p; }
	break;
	case 11:
#line 303 "admin.rl"
	{ strend = p; }
	break;
	case 12:
#line 304 "admin.rl"
	{ state = true; }
	break;
	case 13:
#line 305 "admin.rl"
	{ state = false; }
	break;
	case 14:
#line 309 "admin.rl"
	{return -1;}
	break;
	case 15:
#line 311 "admin.rl"
	{start(out); tarantool_info(out); end(out);}
	break;
	case 16:
#line 312 "admin.rl"
	{start(out); fiber_info(out); end(out);}
	break;
	case 17:
#line 314 "admin.rl"
	{start(out); show_slab(out); end(out);}
	break;
	case 18:
#line 315 "admin.rl"
	{start(out); palloc_stat(out); end(out);}
	break;
	case 19:
#line 316 "admin.rl"
	{start(out); show_stat(out);end(out);}
	break;
	case 20:
#line 320 "admin.rl"
	{coredump(60); ok(out);}
	break;
	case 21:
#line 322 "admin.rl"
	{slab_validate(); ok(out);}
	break;
#line 695 "admin.cc"
		}
	}

_again:
	if ( cs == 0 )
		goto _out;
	if ( ++p != pe )
		goto _resume;
	_test_eof: {}
	_out: {}
	}

#line 328 "admin.rl"


	in->pos = pe;

	if (p != pe) {
		start(out);
		tbuf_append(out, unknown_command, strlen(unknown_command));
		end(out);
	}

	coio_write(coio, out->data, out->size);
	return 0;
}

static void
admin_handler(va_list ap)
{
	struct ev_io coio = va_arg(ap, struct ev_io);
	struct iobuf *iobuf = va_arg(ap, struct iobuf *);
	lua_State *L = lua_newthread(tarantool_L);
	int coro_ref = luaL_ref(tarantool_L, LUA_REGISTRYINDEX);

	auto scoped_guard = make_scoped_guard([&] {
		luaL_unref(tarantool_L, LUA_REGISTRYINDEX, coro_ref);
		evio_close(&coio);
		iobuf_delete(iobuf);
		session_destroy(fiber->sid);
	});

	/*
	 * Admin and iproto connections must have a
	 * session object, representing the state of
	 * a remote client: it's used in Lua
	 * stored procedures.
	 */
	session_create(coio.fd);
	for (;;) {
		if (admin_dispatch(&coio, iobuf, L) < 0)
			return;
		iobuf_gc(iobuf);
		fiber_gc();
	}
}

void
admin_init(const char *bind_ipaddr, int admin_port)
{
	static struct coio_service admin;
	coio_service_init(&admin, "admin", bind_ipaddr,
			  admin_port, admin_handler, NULL);
	evio_service_start(&admin.evio_service);
}

/*
 * Local Variables:
 * mode: c
 * End:
 * vim: syntax=cpp
 */
