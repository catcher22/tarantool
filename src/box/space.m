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
#include "space.h"
#include <stdlib.h>
#include <string.h>
#include <cfg/tarantool_box_cfg.h>
#include <cfg/warning.h>
#include <tarantool.h>
#include <lua/init.h>
#include <exception.h>
#include "tuple.h"
#include <pickle.h>
#include <palloc.h>
#include <assoc.h>
#include <fiber.h>
#include <tbuf.h>

#include <box/box.h>
#include "port.h"
#include "request.h"
#include "box_lua_space.h"

bool secondary_indexes_enabled = false;
bool primary_indexes_enabled = false;

/*
 * Space meta
 */

struct space_meta_field_def {
	u32 field_no;
	enum field_data_type field_type;
};

struct space_meta {
	u32 space_no;
	char name[BOX_SPACE_NAME_MAXLEN];
	u32 arity;
	u32 flags;
	u32 max_fieldno;
	u32 field_defs_count;
	struct space_meta_field_def field_defs[0];
};

static u32
space_meta_calc_load_size_v1(const void *d, u32 field_count);

static u32
space_meta_calc_save_size_v1(const struct space_meta *meta);

static const void *
space_meta_load_v1(struct space_meta *meta, const void *d, u32 field_count);

static void *
space_meta_save_v1(void *d, u32 *p_part_count, const struct space_meta *meta);

/*
 * Index meta
 */

struct index_meta_part {
	u32 field_no;
};

struct index_meta {
	u32 index_no;
	u32 space_no;
	char name[BOX_INDEX_NAME_MAXLEN];
	enum index_type type;
	bool is_unique;
	u32 max_fieldno;
	u32 part_count;
	struct index_meta_part parts[0];
};

static u32
index_meta_calc_load_size_v1(const void *d, u32 field_count);

static const void *
index_meta_load_v1(struct index_meta *meta, const void *d, u32 field_count);

static const void *
index_meta_load_v1(struct index_meta *meta, const void *d, u32 field_count);

static void *
index_meta_save_v1(void *d, u32 *p_part_count,const struct index_meta *meta);

/*
 * Cache
 */

static struct mh_i32ptr_t *spaces_by_no;

static struct space *
space_new(void);

static void
space_delete(struct space *space);

static struct space *
space_cache_get(u32 space_no);

static void
space_cache_put(struct space *space);

static void
space_cache_update(struct space_meta *space_meta, size_t index_count,
		   struct index_meta *index_metas[BOX_INDEX_MAX]);

static void
space_cache_delete(u32 space_no);

static void
space_cache_commit(u32 space_no);

static void
space_cache_rollback(u32 space_no);

/*
 * Key Definition
 */
static void
key_def_create(struct key_def *key_def, const struct index_meta *meta,
	       const enum field_data_type *field_types);

static void
key_def_destroy(struct key_def *key_def);

static bool
key_def_eq(const struct key_def *a, const struct key_def *b);

/*
 * System spaces
 */

static void
space_init_system(void);

static void
space_systrigger_free(struct space_trigger *trigger);

static struct tuple *
space_sysspace_before(struct space_trigger *trigger, struct space *sysspace,
		      struct tuple *old_tuple, struct tuple *new_tuple);

static struct tuple *
space_sysspace_commit(struct space_trigger *trigger, struct space *sysspace,
		      struct tuple *old_tuple, struct tuple *new_tuple);

static struct tuple *
space_sysspace_rollback(struct space_trigger *trigger, struct space *sysspace,
			struct tuple *old_tuple, struct tuple *new_tuple);

static struct tuple *
space_sysindex_before(struct space_trigger *trigger, struct space *sysspace,
		      struct tuple *old_tuple, struct tuple *new_tuple);

static struct tuple *
space_sysindex_commit(struct space_trigger *trigger, struct space *sysspace,
		      struct tuple *old_tuple, struct tuple *new_tuple);

static struct tuple *
space_sysindex_rollback(struct space_trigger *trigger, struct space *sysspace,
			struct tuple *old_tuple, struct tuple *new_tuple);

/*
 * Utils
 */
#define raise_meta_error(fmt, ...) ({					\
	enum { MSG_BUF_SIZE = 1024 };					\
									\
	char msg_buf[MSG_BUF_SIZE];					\
	snprintf(msg_buf, MSG_BUF_SIZE-1, fmt, ##__VA_ARGS__);		\
	msg_buf[MSG_BUF_SIZE-1] = 0;					\
									\
	tnt_raise(IllegalParams, :msg_buf);				\
})

static struct space *
space_new(void)
{
	struct space *sp = calloc(1, sizeof(*sp));
	if (unlikely(sp == NULL)) {
		tnt_raise(LoggedError, :ER_MEMORY_ISSUE, sizeof(*sp),
			  "space", "space");
	}

	sp->no = UINT32_MAX; /* set some invalid id, space_no = 0 is valid */

	rlist_create(&sp->before_triggers);
	rlist_create(&sp->commit_triggers);
	rlist_create(&sp->rollback_triggers);

	return sp;
}

static void
space_delete(struct space *space)
{
	if (space == NULL)
		return;

	for (u32 index_no = 0 ; index_no < BOX_INDEX_MAX; index_no++) {
		if (space->index[index_no] == NULL)
			continue;

		key_def_destroy(&space->key_defs[index_no]);

		if (!space->index_is_shared[index_no]) {
			[space->index[index_no] free];
		}
		space->index[index_no] = NULL;
	}

	struct rlist *triggers[] = {
		&space->before_triggers, &space->commit_triggers,
		&space->rollback_triggers
	};
	for (size_t i = 0; i < lengthof(triggers); i++) {
		struct space_trigger *trigger;
		/* TODO: rlist_foreach_safe */
		rlist_foreach_entry(trigger, triggers[i], link) {
			assert(trigger->free != NULL);
			trigger->free(trigger);
		}
	}

	free(space->field_types);
	free(space);
}

static u32
space_meta_calc_load_size_v1(const void *d, u32 field_count)
{
	if ((field_count - 4) % 2 != 0) {
		raise_meta_error("invalid field count");
	}

	(void) d;

	u32 field_def_count = (field_count - 4) / 2;
	return sizeof(struct space_meta) + field_def_count *
			sizeof(struct space_meta_field_def);
}

static u32
space_meta_calc_save_size_v1(const struct space_meta *meta)
{
	const void *name = meta->name;
	u32 name_len = load_varint32(&name);

	return name_len + varint32_sizeof(name_len) +
			(3 + 2 * meta->field_defs_count) *
			(varint32_sizeof(sizeof(u32)) + sizeof(u32));
}

static const void *
space_meta_load_v1(struct space_meta *meta,
		   const void *d, u32 field_count)
{
	if ((field_count - 4) % 2 != 0) {
		raise_meta_error("invalid field count");
	}

	const void *name = NULL;
	u32 name_len;
	d = load_field_u32(d, &meta->space_no);
	d = load_field_str(d, &name, &name_len);
	d = load_field_u32(d, &meta->arity);
	d = load_field_u32(d, &meta->flags);

	if (name_len + varint32_sizeof(name_len) + 1 >=
			BOX_SPACE_NAME_MAXLEN) {
		raise_meta_error("name is too long");
	}

	assert(name_len + varint32_sizeof(name_len) < BOX_SPACE_NAME_MAXLEN);
	memset(meta->name, 0, sizeof(meta->name));
	save_field_str(meta->name, name, name_len);

	meta->max_fieldno = 0;
	meta->field_defs_count = (field_count - 4) / 2;
	for (u32 i = 0; i < meta->field_defs_count; i++) {
		/* field no */
		u32 field_no;
		d = load_field_u32(d, &field_no);

		/* field type */
		u32 field_type;
		d = load_field_u32(d, &field_type);

		if (meta->max_fieldno < field_no + 1) {
			meta->max_fieldno = field_no + 1;
		}

		meta->field_defs[i].field_no = field_no;
		meta->field_defs[i].field_type = field_type;
	}

	/*
	 * Check type definitions
	 */
	enum field_data_type *new_types = p0alloc(fiber->gc_pool,
			meta->max_fieldno * sizeof(*new_types));

	for (u32 i = 0; i < meta->field_defs_count; i++) {
		if (meta->field_defs[i].field_no >= BOX_FIELD_MAX) {
			raise_meta_error("space_no=%u, field_def=%u: "
					 "invalid field_no",
					 meta->space_no, i);
		}

		if (new_types[meta->field_defs[i].field_no] != UNKNOWN) {
			raise_meta_error("space_no=%u, field_def=%u: "
					 "duplicate field",
					 meta->space_no, i);
		}

		if (meta->field_defs[i].field_type == UNKNOWN ||
		    meta->field_defs[i].field_type >= field_data_type_MAX) {
			raise_meta_error("space_no=%u, field_def=%u: "
					 "invalid field type",
					 meta->space_no, i);
		}

		new_types[meta->field_defs[i].field_no] =
				meta->field_defs[i].field_type;
	}

	return d;
}

static void *
space_meta_save_v1(void *d, u32 *p_part_count, const struct space_meta *meta)
{
	const void *name = meta->name;
	u32 name_len = load_varint32(&name);

	d = save_field_u32(d, meta->space_no);
	d = save_field_str(d, name, name_len);
	d = save_field_u32(d, meta->arity);
	d = save_field_u32(d, meta->flags);
	for (u32 i = 0; i < meta->field_defs_count; i++) {
		d = save_field_u32(d, meta->field_defs[i].field_no);
		d = save_field_u32(d, meta->field_defs[i].field_type);
	}

	*p_part_count = 4 + 2 * meta->field_defs_count;

	return d;
}

static struct space_meta *
space_meta_from_tuple(const struct tuple *tuple)
{
	struct space_meta *meta;
	const void *d = tuple->data;
	u32 m_size = space_meta_calc_load_size_v1(d, tuple->field_count);
	meta = p0alloc(fiber->gc_pool, m_size);
	d = space_meta_load_v1(meta, d, tuple->field_count);
	assert (d = tuple->data + tuple->bsize);
	return meta;
}

static struct tuple *
space_meta_to_tuple(const struct space_meta *meta)
{
	u32 size = space_meta_calc_save_size_v1(meta);
	struct tuple *tuple = tuple_alloc(size);
	void *d = tuple->data;
	d = space_meta_save_v1(d, &tuple->field_count, meta);
	assert(d = tuple->data + tuple->bsize);
	return tuple;
}

static u32
index_meta_calc_load_size_v1(const void *d, u32 field_count)
{
	(void) d;

	u32 fields_count = (field_count - 5);
	return sizeof(struct index_meta) + fields_count * sizeof(u32);
}

static u32
index_meta_calc_save_size_v1(const struct index_meta *meta)
{
	const void *name = meta->name;
	u32 name_len = load_varint32(&name);

	return name_len + varint32_sizeof(name_len) +
			4 * (varint32_sizeof(sizeof(u32)) + sizeof(u32))+
			meta->part_count * sizeof(*meta->parts);
}

static const void *
index_meta_load_v1(struct index_meta *meta, const void *d, u32 field_count)
{
	const void *name = NULL;
	u32 name_len;
	d = load_field_u32(d, &meta->space_no);
	d = load_field_u32(d, &meta->index_no);
	d = load_field_str(d, &name, &name_len);
	u32 type = 0;
	d = load_field_u32(d, &type);
	meta->type = type;
	u32 is_unique;
	d = load_field_u32(d, &is_unique);
	meta->is_unique = (is_unique != 0);

	if (name_len + varint32_sizeof(name_len) + 1 >=
			BOX_INDEX_NAME_MAXLEN) {
		raise_meta_error("space_no=%u: name is too long",
				 meta->space_no);
	}

	assert(name_len + varint32_sizeof(name_len) < BOX_SPACE_NAME_MAXLEN);
	memset(meta->name, 0, sizeof(meta->name));
	save_field_str(meta->name, name, name_len);

	meta->max_fieldno = 0;
	meta->part_count = (field_count - 5);
	for (u32 part = 0; part < meta->part_count; part++) {
		/* field no */
		u32 field_no;
		d = load_field_u32(d, &field_no);

		if (meta->max_fieldno < field_no + 1) {
			meta->max_fieldno = field_no + 1;
		}

		meta->parts[part].field_no = field_no;
	}

	if (meta->part_count == 0) {
		raise_meta_error("space_no=%u, index_no=%u: "
				 "need at least one indexed field",
				 meta->space_no, meta->index_no);
	}

	return d;
}

static void *
index_meta_save_v1(void *d, u32 *p_field_count, const struct index_meta *meta)
{
	const void *name = meta->name;
	u32 name_len = load_varint32(&name);

	d = save_field_u32(d, meta->space_no);
	d = save_field_u32(d, meta->index_no);
	d = save_field_str(d, name, name_len);
	d = save_field_u32(d, meta->type);
	d = save_field_u32(d, meta->is_unique);
	for (u32 i = 0; i < meta->part_count; i++) {
		d = save_field_u32(d, meta->parts[i].field_no);
	}

	*p_field_count = 5 + meta->part_count;

	return d;
}

static struct index_meta *
index_meta_from_tuple(const struct tuple *tuple)
{
	struct index_meta *meta;
	const void *d = tuple->data;
	u32 m_size = index_meta_calc_load_size_v1(d, tuple->field_count);
	meta = p0alloc(fiber->gc_pool, m_size);
	d = index_meta_load_v1(meta, d, tuple->field_count);
	assert (d = tuple->data + tuple->bsize);
	return meta;
}

static struct tuple *
index_meta_to_tuple(const struct index_meta *meta)
{
	u32 size = index_meta_calc_save_size_v1(meta);
	struct tuple *tuple = tuple_alloc(size);
	void *d = tuple->data;
	d = index_meta_save_v1(d, &tuple->field_count, meta);
	assert(d = tuple->data + tuple->bsize);
	return tuple;
}


static void
space_systrigger_free(struct space_trigger *trigger)
{
	free(trigger);
}

static struct tuple *
space_sysspace_before(struct space_trigger *trigger, struct space *sysspace,
		      struct tuple *old_tuple, struct tuple *new_tuple)
{
	(void) trigger;
	(void) sysspace;

	if (new_tuple == NULL) {
		/*
		 * Delete space
		 */
		struct space_meta *meta = space_meta_from_tuple(old_tuple);
		space_cache_delete(meta->space_no);

		return NULL;
	}

	assert (new_tuple != NULL);

	/*
	 * Parse new space meta
	 */
	struct space_meta *space_meta = space_meta_from_tuple(new_tuple);
	size_t index_count = 0;
	struct index_meta *index_metas[BOX_INDEX_MAX];

	/*
	 * Check that meta for super spaces is not changing
	 */
	if (space_meta->space_no == BOX_SYSSPACE_NO ||
	    space_meta->space_no == BOX_SYSINDEX_NO) {
		if (!primary_indexes_enabled) {
			return NULL;
		}

		raise_meta_error("space_no=%u: cannot change the system space",
				 space_meta->space_no);
	}

	if (space_meta->space_no >= BOX_SPACE_MAX) {
		raise_meta_error("space_no=%u: invalid space_no (>%u)",
				 space_meta->space_no, BOX_SPACE_MAX);
	}

	/*
	 * Get indexes
	 */
	if (old_tuple != NULL) {
		struct space *sysindex = space_find_by_no(BOX_SYSINDEX_NO);
		Index *sysindex_pk = index_find_by_no(sysindex, 0);

		char space_key[varint32_sizeof(BOX_SPACE_MAX) + sizeof(u32)];
		save_field_u32(space_key, space_meta->space_no);
		struct iterator *it = [sysindex_pk allocIterator];
		@try {
			[sysindex_pk initIterator: it :ITER_EQ :space_key :1];
			struct tuple *index_tuple = NULL;
			while ( (index_tuple = it->next(it)) != NULL) {
				index_metas[index_count++] =
					index_meta_from_tuple(index_tuple);
			}
		} @finally {
			it->free(it);
		}
	}

	/*
	 * Prepare new space cache
	 */
	space_cache_update(space_meta, index_count, index_metas);

	return new_tuple;
}

static struct tuple *
space_sysspace_commit(struct space_trigger *trigger, struct space *sysspace,
		      struct tuple *old_tuple, struct tuple *new_tuple)
{
	(void) trigger;
	(void) sysspace;
	(void) old_tuple;

	u32 space_no;
	if (new_tuple) {
		/* REPLACE or INSERT */
		struct space_meta *meta = space_meta_from_tuple(new_tuple);
		space_no = meta->space_no;
	} else if (old_tuple) {
		/* DELETE */
		struct space_meta *meta = space_meta_from_tuple(old_tuple);
		space_no = meta->space_no;
	} else {
		assert (false);
	}

	/*
	 * Commit space meta
	 */
	if (space_no == BOX_SYSSPACE_NO || space_no == BOX_SYSINDEX_NO) {
		assert (!primary_indexes_enabled);
		return new_tuple;
	}

	space_cache_commit(space_no);

	return new_tuple;
}

static struct tuple *
space_sysspace_rollback(struct space_trigger *trigger, struct space *sysspace,
			struct tuple *old_tuple, struct tuple *new_tuple)
{
	(void) trigger;
	(void) sysspace;
	(void) old_tuple;

	u32 space_no;
	if (new_tuple) {
		/* REPLACE or INSERT */
		struct space_meta *meta = space_meta_from_tuple(new_tuple);
		space_no = meta->space_no;
	} else if (old_tuple) {
		/* DELETE */
		struct space_meta *meta = space_meta_from_tuple(old_tuple);
		space_no = meta->space_no;
	} else {
		assert (false);
	}

	/*
	 * Rollback space meta
	 */

	space_cache_rollback(space_no);

	return new_tuple;
}

static struct tuple *
space_sysindex_before(struct space_trigger *trigger, struct space *sysindex,
		      struct tuple *old_tuple, struct tuple *new_tuple)
{
	(void) trigger;

	assert (old_tuple != NULL || new_tuple != NULL);

	/*
	 * Parse old and new space tuples
	 */
	struct index_meta *new_index_meta = NULL;
	struct index_meta *old_index_meta = NULL;
	u32 space_no;
	if (old_tuple && new_tuple) {
		/* replace */
		old_index_meta = index_meta_from_tuple(old_tuple);
		new_index_meta = index_meta_from_tuple(new_tuple);
		assert (old_index_meta->space_no == new_index_meta->space_no);
		space_no = old_index_meta->space_no;
		if (old_index_meta->space_no != old_index_meta->space_no) {
			raise_meta_error("space_no=%u ,index_no=%u: "
					 "cannot change space_no",
					 old_index_meta->space_no,
					 old_index_meta->index_no);
		}

		if (old_index_meta->index_no != old_index_meta->index_no) {
			raise_meta_error("space_no=%u ,index_no=%u: "
					 "cannot change index_no",
					 old_index_meta->space_no,
					 old_index_meta->index_no);
		}
	} else if (new_tuple) {
		/* insert */
		new_index_meta = index_meta_from_tuple(new_tuple);
		space_no = new_index_meta->space_no;
	} else if (old_tuple) {
		/* delete */
		old_index_meta = index_meta_from_tuple(old_tuple);
		space_no = old_index_meta->space_no;
	} else {
		assert(false);
	}

	/*
	 * Check that system spaces are not affected
	 */
	if (space_no == BOX_SYSSPACE_NO || space_no == BOX_SYSINDEX_NO) {
		if (!primary_indexes_enabled) {
			return NULL;
		}
		raise_meta_error("space_no=%u: cannot change system spaces",
				 space_no);
	}

	if (new_tuple && new_index_meta->index_no >= BOX_INDEX_MAX) {
		raise_meta_error("space_no=%u, index_no=%u: "
				 "invalid index_no (> %u)",
				 new_index_meta->space_no,
				 new_index_meta->index_no,
				 BOX_INDEX_MAX);
	}

	struct space_meta *space_meta;
	size_t index_count = 0;
	struct index_meta *index_metas[BOX_INDEX_MAX];

	struct space *sysspace = space_find_by_no(BOX_SYSSPACE_NO);
	Index *sysspace_pk = index_find_by_no(sysspace, 0);
	Index *sysindex_pk = index_find_by_no(sysindex, 0);

	char space_key[varint32_sizeof(BOX_SPACE_MAX) + sizeof(u32)];
	save_field_u32(space_key, space_no);

	/*
	 * Get metadata for space
	 */
	struct tuple *space_tuple = [sysspace_pk findByKey: space_key :1];
	if (space_tuple == NULL) {
		raise_meta_error("space_no=%u: space does not exist",
				 space_no);
	}
	space_meta = space_meta_from_tuple(space_tuple);

	/*
	 * Get metadata for indexes
	 */
	struct iterator *it = [sysindex_pk allocIterator];
	@try {
		[sysindex_pk initIterator: it :ITER_EQ :space_key :1];
		struct tuple *index_tuple;
		struct index_meta *index_meta;
		while ( (index_tuple = it->next(it)) != NULL) {
			index_meta = index_meta_from_tuple(index_tuple);
			if (old_tuple && index_meta->index_no ==
					 old_index_meta->index_no) {
				/* Skip deleted index */
				continue;
			}
			if (new_tuple && index_meta->index_no ==
					 new_index_meta->index_no) {
				/* Skip update index (add below) */
				continue;
			}

			index_metas[index_count++] = index_meta;
		}
	} @finally {
		it->free(it);
	}

	if (new_tuple) {
		/* Add new/updated index */
		index_metas[index_count++] = new_index_meta;
	}

	/*
	 * Prepare new space cache
	 */
	space_cache_update(space_meta, index_count, index_metas);

	return new_tuple;
}

static struct tuple *
space_sysindex_commit(struct space_trigger *trigger, struct space *sysspace,
		      struct tuple *old_tuple, struct tuple *new_tuple)
{
	(void) trigger;
	(void) sysspace;

	u32 space_no;
	if (new_tuple) {
		struct index_meta *meta = index_meta_from_tuple(new_tuple);
		space_no = meta->space_no;
	} else {
		assert (old_tuple != NULL);
		struct index_meta *meta = index_meta_from_tuple(old_tuple);
		space_no = meta->space_no;
	}

	if (space_no == BOX_SYSSPACE_NO || space_no == BOX_SYSINDEX_NO) {
		assert (!primary_indexes_enabled);
		return new_tuple;
	}

	/*
	 * Commit space meta
	 */
	space_cache_commit(space_no);

	return new_tuple;
}

static struct tuple *
space_sysindex_rollback(struct space_trigger *trigger, struct space *sysspace,
			struct tuple *old_tuple, struct tuple *new_tuple)
{
	(void) trigger;
	(void) sysspace;

	u32 space_no;
	if (new_tuple) {
		struct index_meta *meta = index_meta_from_tuple(new_tuple);
		space_no = meta->space_no;
	} else {
		assert (old_tuple != NULL);
		struct index_meta *meta = index_meta_from_tuple(old_tuple);
		space_no = meta->space_no;
	}

	/*
	 * Rollback space meta
	 */
	space_cache_rollback(space_no);

	return new_tuple;
}


static void
space_init_system(void)
{
	/*
	 * sys_space
	 */
	struct space_meta *sysspace_meta = p0alloc(fiber->gc_pool,
				sizeof(*sysspace_meta) + 4 *
				sizeof(*sysspace_meta->field_defs));
	sysspace_meta->space_no = BOX_SYSSPACE_NO;
	save_field_str(sysspace_meta->name, BOX_SYSSPACE_NAME,
		       strlen(BOX_SYSSPACE_NAME));
	sysspace_meta->arity = 0;
	sysspace_meta->flags = 0;
	sysspace_meta->max_fieldno = 4;
	sysspace_meta->field_defs_count = 4;
	sysspace_meta->field_defs[0].field_no = 0;
	sysspace_meta->field_defs[0].field_type = NUM;
	sysspace_meta->field_defs[1].field_no = 1;
	sysspace_meta->field_defs[1].field_type = STRING;
	sysspace_meta->field_defs[2].field_no = 2;
	sysspace_meta->field_defs[2].field_type = NUM;
	sysspace_meta->field_defs[3].field_no = 3;
	sysspace_meta->field_defs[3].field_type = NUM;

	size_t sysspace_idx_count = 2;
	struct index_meta *sysspace_idx_metas[2];

	sysspace_idx_metas[0] = p0alloc(fiber->gc_pool,
					sizeof(*sysspace_idx_metas[0]) + 1 *
					sizeof(*sysspace_idx_metas[0]->parts));

	sysspace_idx_metas[0]->space_no = BOX_SYSSPACE_NO;
	sysspace_idx_metas[0]->index_no = 0;
	save_field_str(sysspace_idx_metas[0]->name, "pk", strlen("pk"));
	sysspace_idx_metas[0]->type = TREE;
	sysspace_idx_metas[0]->is_unique = true;
	sysspace_idx_metas[0]->max_fieldno = 1;
	sysspace_idx_metas[0]->part_count = 1;
	sysspace_idx_metas[0]->parts[0].field_no = 0;

	sysspace_idx_metas[1] = p0alloc(fiber->gc_pool,
					sizeof(*sysspace_idx_metas[1]) + 1 *
					sizeof(*sysspace_idx_metas[1]->parts));

	sysspace_idx_metas[1]->space_no = BOX_SYSSPACE_NO;
	sysspace_idx_metas[1]->index_no = 1;
	save_field_str(sysspace_idx_metas[1]->name, "name", strlen("name"));
	sysspace_idx_metas[1]->type = TREE;
	sysspace_idx_metas[1]->is_unique = true;
	sysspace_idx_metas[1]->max_fieldno = 2;
	sysspace_idx_metas[1]->part_count = 1;
	sysspace_idx_metas[1]->parts[0].field_no = 1;

	/*
	 * sys_index
	 */
	struct space_meta *sysindex_meta = p0alloc(fiber->gc_pool,
				sizeof(*sysindex_meta) + 5 *
				sizeof(*sysindex_meta->field_defs));
	sysindex_meta->space_no = BOX_SYSINDEX_NO;
	save_field_str(sysindex_meta->name, BOX_SYSINDEX_NAME,
		       strlen(BOX_SYSINDEX_NAME));
	sysindex_meta->arity = 0;
	sysindex_meta->max_fieldno = 5;
	sysindex_meta->flags = 0;
	sysindex_meta->field_defs_count = 5;
	sysindex_meta->field_defs[0].field_no = 0;
	sysindex_meta->field_defs[0].field_type = NUM;
	sysindex_meta->field_defs[1].field_no = 1;
	sysindex_meta->field_defs[1].field_type = NUM;
	sysindex_meta->field_defs[2].field_no = 2;
	sysindex_meta->field_defs[2].field_type = STRING;
	sysindex_meta->field_defs[3].field_no = 3;
	sysindex_meta->field_defs[3].field_type = NUM;
	sysindex_meta->field_defs[4].field_no = 4;
	sysindex_meta->field_defs[4].field_type = NUM;

	size_t sysindex_idx_count = 2;
	struct index_meta *sysindex_idx_metas[2];

	sysindex_idx_metas[0] = p0alloc(fiber->gc_pool,
					sizeof(*sysindex_idx_metas[0]) + 2 *
					sizeof(*sysindex_idx_metas[0]->parts));

	sysindex_idx_metas[0]->space_no = BOX_SYSINDEX_NO;
	sysindex_idx_metas[0]->index_no = 0;
	save_field_str(sysindex_idx_metas[0]->name, "pk", strlen("pk"));
	sysindex_idx_metas[0]->type = TREE;
	sysindex_idx_metas[0]->is_unique = true;
	sysindex_idx_metas[0]->max_fieldno = 2;
	sysindex_idx_metas[0]->part_count = 2;
	sysindex_idx_metas[0]->parts[0].field_no = 0;
	sysindex_idx_metas[0]->parts[1].field_no = 1;

	sysindex_idx_metas[1] = p0alloc(fiber->gc_pool,
					sizeof(*sysindex_idx_metas[1]) + 2 *
					sizeof(*sysindex_idx_metas[1]->parts));

	sysindex_idx_metas[1]->space_no = BOX_SYSINDEX_NO;
	sysindex_idx_metas[1]->index_no = 1;
	save_field_str(sysindex_idx_metas[1]->name, "name", strlen("name"));
	sysindex_idx_metas[1]->type = TREE;
	sysindex_idx_metas[1]->is_unique = true;
	sysindex_idx_metas[1]->max_fieldno = 3;
	sysindex_idx_metas[1]->part_count = 2;
	sysindex_idx_metas[1]->parts[0].field_no = 0;
	sysindex_idx_metas[1]->parts[0].field_no = 2;

	struct space *sysspace = NULL;
	struct space *sysindex = NULL;
	struct tuple *sysspace_tuple = NULL;
	struct tuple *sysspace_idx_tuple_0 = NULL;
	struct tuple *sysspace_idx_tuple_1 = NULL;
	struct tuple *sysindex_tuple = NULL;
	struct tuple *sysindex_idx_tuple_0 = NULL;
	struct tuple *sysindex_idx_tuple_1 = NULL;


	@try {
		/*
		 * System Space
		 */
		space_cache_update(sysspace_meta, sysspace_idx_count,
				   sysspace_idx_metas);
		sysspace = space_cache_get(BOX_SYSSPACE_NO);

		struct space_trigger *before;
		struct space_trigger *commit;
		struct space_trigger *rollback;

		/* Before trigger */
		before = calloc(1, sizeof(*before));
		if (before == NULL) {
			tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
				  sizeof(*before), "space",
				  "check_trigger");
		}
		before->free = space_systrigger_free;
		before->trigger = space_sysspace_before;
		rlist_add_entry(&sysspace->before_triggers, before, link);

		/* Commit trigger */
		commit = calloc(1, sizeof(*commit));
		if (commit == NULL) {
			tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
				  sizeof(*commit), "space",
				  "commit_trigger");
		}
		commit->free = space_systrigger_free;
		commit->trigger = space_sysspace_commit;
		rlist_add_entry(&sysspace->commit_triggers, commit, link);

		/* Rollback trigger */
		rollback = calloc(1, sizeof(*rollback));
		if (rollback == NULL) {
			tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
				  sizeof(*rollback), "space",
				  "rollback_trigger");
		}
		rollback->free = space_systrigger_free;
		rollback->trigger = space_sysspace_rollback;
		rlist_add_entry(&sysspace->rollback_triggers, rollback, link);

		/*
		 * System Index
		 */
		space_cache_update(sysindex_meta, sysindex_idx_count,
				   sysindex_idx_metas);
		sysindex = space_cache_get(BOX_SYSINDEX_NO);

		/* Before trigger */
		before = calloc(1, sizeof(*before));
		if (before == NULL) {
			tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
				  sizeof(*before), "space",
				  "check_trigger");
		}
		before->free = space_systrigger_free;
		before->trigger = space_sysindex_before;
		rlist_add_entry(&sysindex->before_triggers, before, link);

		/* Commit trigger */
		commit = calloc(1, sizeof(*commit));
		if (commit == NULL) {
			tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
				  sizeof(*commit), "space",
				  "commit_trigger");
		}
		commit->free = space_systrigger_free;
		commit->trigger = space_sysindex_commit;
		rlist_add_entry(&sysindex->commit_triggers, commit, link);

		/* Rollback trigger */
		rollback = calloc(1, sizeof(*rollback));
		if (rollback == NULL) {
			tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
				  sizeof(*rollback), "space",
				  "rollback_trigger");
		}
		rollback->free = space_systrigger_free;
		rollback->trigger = space_sysindex_rollback;
		rlist_add_entry(&sysindex->rollback_triggers, rollback, link);

		sysspace_tuple = space_meta_to_tuple(sysspace_meta);
		sysspace_idx_tuple_0 = index_meta_to_tuple(sysspace_idx_metas[0]);
		sysspace_idx_tuple_1 = index_meta_to_tuple(sysspace_idx_metas[1]);

		sysindex_tuple = space_meta_to_tuple(sysindex_meta);
		sysindex_idx_tuple_0 = index_meta_to_tuple(sysindex_idx_metas[0]);
		sysindex_idx_tuple_1 = index_meta_to_tuple(sysindex_idx_metas[1]);

		assert (sysspace->index[0] != NULL);
		assert (sysindex->index[0] != NULL);

		[sysspace->index[0] beginBuild];
		[sysspace->index[0] endBuild];
		[sysindex->index[0] beginBuild];
		[sysindex->index[0] endBuild];

		space_recovery_next(sysspace, sysspace_tuple);
		space_recovery_next(sysspace, sysindex_tuple);

		space_recovery_next(sysindex, sysspace_idx_tuple_0);
		space_recovery_next(sysindex, sysspace_idx_tuple_1);
		space_recovery_next(sysindex, sysindex_idx_tuple_0);
		space_recovery_next(sysindex, sysindex_idx_tuple_1);
	} @catch(tnt_Exception *e) {
		[e log];
		tuple_free(sysspace_tuple);
		tuple_free(sysspace_idx_tuple_0);
		tuple_free(sysspace_idx_tuple_1);
		tuple_free(sysindex_tuple);
		tuple_free(sysindex_idx_tuple_0);
		tuple_free(sysindex_idx_tuple_1);

		space_cache_rollback(BOX_SYSSPACE_NO);
		space_cache_rollback(BOX_SYSINDEX_NO);
		@throw;
	}

	space_cache_commit(BOX_SYSSPACE_NO);
	space_cache_commit(BOX_SYSINDEX_NO);
}


static void
key_def_create(struct key_def *key_def, const struct index_meta *meta,
	       const enum field_data_type *field_types)
{
	size_t sz = 0;

	memset(key_def, 0, sizeof(*key_def));

	key_def->type = meta->type;
	key_def->is_unique = meta->is_unique;

	key_def->part_count = meta->part_count;
	sz = sizeof(*key_def->parts) * key_def->part_count;
	key_def->parts = malloc(sz);
	if (key_def->parts == NULL)
		goto error_1;

	key_def->max_fieldno = meta->max_fieldno;

	sz = key_def->max_fieldno * sizeof(u32);
	key_def->cmp_order = malloc(sz);
	if (key_def->cmp_order == NULL)
		goto error_2;

	for (u32 field_no = 0; field_no < key_def->max_fieldno; field_no++) {
		key_def->cmp_order[field_no] = BOX_FIELD_MAX;
	}

	for (u32 part = 0; part < key_def->part_count; part++) {
		u32 field_no = meta->parts[part].field_no;
		key_def->parts[part].fieldno = field_no;
		assert(field_no < key_def->max_fieldno);
		key_def->parts[part].type = field_types[field_no];
		assert(key_def->parts[part].type != UNKNOWN);
		key_def->cmp_order[field_no] = part;
	}

	return;

error_2:
	free(key_def->parts);
error_1:
	key_def->parts = NULL;
	key_def->cmp_order = NULL;
	tnt_raise(LoggedError, :ER_MEMORY_ISSUE, sz, "space", "index");
}

static void
key_def_destroy(struct key_def *key_def)
{
	free(key_def->parts);
	free(key_def->cmp_order);
	key_def->parts = NULL;
	key_def->cmp_order = NULL;
}

static bool
key_def_eq(const struct key_def *a, const struct key_def *b)
{
	if (a->type != b->type ||
	    a->is_unique != b->is_unique ||
	    a->part_count != b->part_count) {
		return false;
	}

	for (u32 part = 0; part < a->part_count; part++) {
		if (a->parts[part].fieldno != b->parts[part].fieldno ||
		    a->parts[part].type != b->parts[part].type) {
			return false;
		}
	}

	assert (memcmp(a->cmp_order, b->cmp_order,
		       a->max_fieldno * sizeof(u32)) == 0);

	return true;
}

static struct space *
space_cache_get(u32 space_no)
{
	struct mh_i32ptr_node_t no_node = { .key = space_no };
	mh_int_t pos = mh_i32ptr_get(spaces_by_no, &no_node, NULL, NULL);
	if (pos != mh_end(spaces_by_no)) {
		return mh_i32ptr_node(spaces_by_no, pos)->val;
	}

	return NULL;
}

static void
space_cache_put(struct space *space)
{
	struct mh_i32ptr_node_t no_node;
	no_node.key = space->no;
	no_node.val = space;

	uint32_t pos = mh_i32ptr_replace(spaces_by_no, &no_node, NULL,
					NULL, NULL);
	if (pos == mh_end(spaces_by_no)) {
		tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
			  sizeof(no_node), "spaces_by_no", "space");
	}
}

static void
space_cache_update_index(struct space *old_space, struct space *new_space,
			 struct index_meta *index_m)
{
	assert (new_space != NULL);
	assert (index_m != NULL);
	assert (index_m->index_no < BOX_INDEX_MAX);
	assert (index_m->part_count > 0);
	assert (new_space->index[index_m->index_no] == NULL);
	assert (new_space->no == index_m->space_no);

	u32 index_no = index_m->index_no;

	/*
	 * Check index parameters
	 */
	if (index_m->type >= index_type_MAX) {
		raise_meta_error("space_no=%u, index_no=%u: "
				 "invalid index type",
				 index_m->space_no, index_m->index_no);
	}

	if (index_m->part_count > 1 &&
	    (index_m->type == HASH /* || new_index_m->type == BITSET */)) {
		raise_meta_error("space_no=%u, index_no=%u: "
				 "this type of index must be single-part",
				 index_m->space_no, index_m->index_no);
	}

	if (!index_m->is_unique &&
	    (index_m->type == HASH /* || new_index_m->type == BITSET */)) {
		raise_meta_error("space_no=%u, index_no=%u: "
				 "this type of index must be unique",
				 index_m->space_no, index_m->index_no);
	}

	/* Check that all indexed fields are defined */
	for (u32 part = 0; part < index_m->part_count; part++){
		u32 field_no = index_m->parts[part].field_no;
		if (field_no >= new_space->max_fieldno ||
		    new_space->field_types[field_no] == UNKNOWN) {
			raise_meta_error("space_no=%u, index_no %u: "
					  "field %u is not defined",
					  index_m->space_no, index_m->index_no,
					  index_m->parts[part].field_no);
		}
	}

	/* Create a new key_def */
	key_def_create(&new_space->key_defs[index_no], index_m,
		       new_space->field_types);

	/* Save index name */
	memcpy(new_space->index_name[index_no], index_m->name,
	       BOX_INDEX_NAME_MAXLEN);

	/* Check if a key_def is not changed */
	if (old_space != NULL && old_space->index[index_no] != NULL &&
	    key_def_eq(&old_space->key_defs[index_no],
		       &new_space->key_defs[index_no])) {

		say_debug("Space %u Index %u: key definition is not changed",
			  new_space->no, index_no);
		/* Share the current index between old and new spaces */
		assert(old_space != NULL && old_space->index[index_no] != NULL);
		new_space->index[index_no] = old_space->index[index_no];
		new_space->index_is_shared[index_no] = true;
		return;
	}

	say_debug("Space %u Index %u: key definition was changed",
		  new_space->no, index_no);

	@try {
		/* Create a new index */
		struct key_def *key_def = &new_space->key_defs[index_no];
		new_space->index[index_no] = [[Index alloc :key_def->type
				:key_def :new_space] init :key_def :new_space];
		/* index_no */
		new_space->index[index_no]->no = index_no;
	} @catch(tnt_Exception *) {
		key_def_destroy(&new_space->key_defs[index_no]);
		if (new_space->index[index_no] != NULL) {
			[new_space->index[index_no] free];
			new_space->index[index_no] = NULL;
		}
		@throw;
	}
}

static void
space_cache_update2(struct space *old_space, struct space *new_space,
		    struct space_meta *space_meta, size_t index_count,
		    struct index_meta *index_metas[BOX_INDEX_MAX])
{
	bool has_data = false;
	if (old_space) {
		if (old_space->state != SPACE_CONFIGURED ||
		    old_space->shadow != NULL) {
			raise_meta_error("space_no=%u: " "space is locked",
					 old_space->no);
		}
		has_data = space_size(old_space) > 0;
		assert (!has_data || primary_indexes_enabled);
	}

	/*
	 * Set space_no
	 */
	new_space->no = space_meta->space_no;

	/*
	 * Set name
	 */
	const void *name = space_meta->name;
	u32 name_len = load_varint32(&name);
	save_field_str(new_space->name, name, name_len);

	/*
	 * Set arity
	 */
	new_space->arity = space_meta->arity;

	/*
	 * Set flags
	 */
	if (has_data && old_space->flags != space_meta->flags) {
		raise_meta_error("space_no=%u: "
				 "flags are read-only, "
				 "because space is not empty",
				 space_meta->space_no);
	}
	new_space->flags = space_meta->flags;

	/*
	 * Set field types
	 */
	assert (new_space->field_types == NULL);
	new_space->max_fieldno = space_meta->max_fieldno;
	new_space->field_types = calloc(new_space->max_fieldno,
				    sizeof(*new_space->field_types));
	if (new_space->field_types == NULL) {
		tnt_raise(LoggedError, :ER_MEMORY_ISSUE, new_space->max_fieldno *
			  sizeof(*new_space->field_types),
			  "space", "field types");
	}

	for (u32 i = 0; i < space_meta->field_defs_count; i++) {
		u32 field_no = space_meta->field_defs[i].field_no;
		/* duplicates checked by space_meta_load_v1 */
		assert (new_space->field_types[field_no] == UNKNOWN);

		new_space->field_types[field_no] =
				space_meta->field_defs[i].field_type;
	}

	/*
	 * Set indexes
	 */
	for (u32 i = 0; i < index_count; i++) {
		struct index_meta *index_meta = index_metas[i];
		space_cache_update_index(old_space, new_space, index_meta);
	}

	/* Check pk */
	if (new_space->index[0] != NULL) {
		if (!new_space->key_defs[0].is_unique) {
			raise_meta_error("space_no=%u: "
					 "primary key must be unique",
					 new_space->no);
		}
	} else if (has_data) {
		raise_meta_error("space_no=%u: "
				 "primary key is not configured",
				 new_space->no);
	}

	/*
	 * Initialize indexes
	 */
	u32 index_init_count;
	if (primary_indexes_enabled) {
		if (secondary_indexes_enabled) {
			/* Init all indexes */
			index_init_count = BOX_INDEX_MAX;
		} else {
			/* Init only PK */
			index_init_count = 1;
		}
	} else {
		/* Do not init indexes */
		index_init_count = 0;
	}

	if (!has_data) {
		/*
		 * Space is empty => just init indexes.
		 */
		for (u32 index_no = 0; index_no < index_init_count; index_no++){
			if (new_space->index[index_no] == NULL ||
			    new_space->index_is_shared[index_no])
				continue;

			[new_space->index[index_no] beginBuild];
			[new_space->index[index_no] endBuild];
		}
	} else {
		/*
		 * Space is not empty => init indexes and copy data.
		 */
		assert (old_space != NULL);
		assert (primary_indexes_enabled);

		Index *pk = index_find_by_no(old_space, 0);

		/* Check that data is compatible with new space */
		say_info("Space %u: begin validating the new schema",
			 new_space->no);
		struct iterator *it = [pk allocIterator];
		@try {
			[pk initIterator: it :ITER_ALL :NULL :0];
			struct tuple *tuple = NULL;
			while ((tuple = it->next(it))) {
				space_validate_tuple(new_space, tuple);
			}
		} @finally {
			it->free(it);
		}
		say_info("Space %u: end validating the new schema",
			 new_space->no);

		/* Insert data into new indexes */
		for (u32 index_no = 0; index_no < index_init_count; index_no++){
			if (new_space->index[index_no] == NULL ||
			    new_space->index_is_shared[index_no])
				continue;

			say_info("Space %u: begin rebuilding index %u",
				 new_space->no, index_no);
			Index *index = index_find_by_no(new_space, index_no);
			/* Index::build does not check tuples */
			[index build: pk];
			say_info("Space %u: end rebuilding index %u",
				 new_space->no, index_no);
		}
	}

	/*
	 * Save space cache
	 */
	if (old_space != NULL) {
		old_space->shadow = new_space;
	} else {
		struct mh_i32ptr_node_t no_node;
		no_node.key = space_meta->space_no;
		no_node.val = new_space;
		uint32_t pos = mh_i32ptr_replace(spaces_by_no, &no_node,
						 NULL, NULL, NULL);
		if (pos == mh_end(spaces_by_no)) {
			tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
				  sizeof(no_node), "spaces_by_no", "space");
		}
	}

}

static void
space_cache_update(struct space_meta *space_meta, size_t index_count,
		   struct index_meta *index_metas[BOX_INDEX_MAX])
{
	struct space *old_space = NULL;
	struct mh_i32ptr_node_t no_node = { .key = space_meta->space_no };
	mh_int_t pos = mh_i32ptr_get(spaces_by_no, &no_node, NULL, NULL);
	if (pos != mh_end(spaces_by_no)) {
		old_space = mh_i32ptr_node(spaces_by_no, pos)->val;
	}

	struct space *new_space = space_new();
	if (new_space == NULL) {
		tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
			  sizeof(*new_space), "space", "cache");
	}

	@try {
		say_info("Space %u: begin creating a new schema",
			 space_meta->space_no);
		space_cache_update2(old_space, new_space, space_meta,
				    index_count, index_metas);
		say_info("Space %u: end creating a new schema",
			 space_meta->space_no);
	} @catch (tnt_Exception *e) {
		say_error("Space %u: failed to create a new schema",
			  space_meta->space_no);
		space_delete(new_space);
		@throw;
	}
}

static void
space_cache_delete(u32 space_no)
{
	struct space *space = space_cache_get(space_no);
	assert (space != NULL);

	if (space_no == BOX_SYSSPACE_NO || space_no == BOX_SYSINDEX_NO) {
		raise_meta_error("space_no=%u: "
				 "cannot change system spaces",
				 space_no);
	}

	if (space->state != SPACE_CONFIGURED || space->shadow != NULL) {
		raise_meta_error("space_no=%u: " "space is locked",
				 space->no);
	}

	if (space_size(space) > 0) {
		raise_meta_error("space_no=%u: "
				 "space is not empty",
				 space->no);
	}

	for (u32 index_no = 0; index_no < BOX_INDEX_MAX; index_no++) {
		if (space->index[index_no] != NULL) {
			raise_meta_error("space_no=%u: "
					 "space has indexes",
					 space->no);
		}
	}

	space->state = SPACE_DELETED;
}

static void
space_cache_commit(u32 space_no)
{
	struct space *space = space_cache_get(space_no);
	assert (space != NULL);

	if (space->shadow == NULL) {
		if (space->state == SPACE_DELETED) {
			if (tarantool_L != NULL)  {
				box_lua_space_del(tarantool_L, space);
			}

			space_delete(space);
		} else if (space->state == SPACE_NEW) {
			space->state = SPACE_CONFIGURED;

			if (tarantool_L != NULL)  {
				box_lua_space_put(tarantool_L, space);
			}
		} else {
			assert(false);
		}
		return;
	}

	/*
	 * Commit cache
	 */
	@try {
		space_cache_put(space->shadow);
	} @catch(tnt_Exception *e) {
		space_delete(space->shadow);
		space->shadow = NULL;
		@throw;
	}

	/*
	 * Transfer ownership of shared indexes
	 */
	for (u32 index_no = 0; index_no < BOX_INDEX_MAX; index_no++) {
		if (!space->shadow->index_is_shared[index_no])
			continue;

		space->index_is_shared[index_no] = true;
		space->shadow->index_is_shared[index_no] = false;
		space->shadow->index[index_no]->space = space->shadow;
		space->shadow->index[index_no]->key_def =
				&space->shadow->key_defs[index_no];
	}

	/*
	 * Transfer ownership of triggers
	 */
	while (!rlist_empty(&space->before_triggers)) {
		rlist_move(rlist_first(&space->before_triggers),
			   &space->shadow->before_triggers);
	}
	rlist_create(&space->before_triggers);
	rlist_create(&space->commit_triggers);
	rlist_create(&space->rollback_triggers);

	space->shadow->state = SPACE_CONFIGURED;
	space->state = SPACE_DELETED;

	if (tarantool_L != NULL)  {
		box_lua_space_del(tarantool_L, space);
		box_lua_space_put(tarantool_L, space->shadow);
		return;
	}

	space_delete(space);
}

static void
space_cache_rollback(u32 space_no)
{
	struct space *space = space_cache_get(space_no);
	assert (space != NULL);

	if (space->shadow == NULL) {
		if (space->state == SPACE_DELETED) {
			/* Deleted space */
			space->state = SPACE_CONFIGURED;
		} else if (space->state == SPACE_NEW){
			/* New space */
			space_delete(space);
		} else {
			assert (false);
		}
		return;
	}

	assert (space->state == SPACE_CONFIGURED);
	assert (space->shadow->state == SPACE_NEW);
	space_delete(space->shadow);
	space->shadow = NULL;
}

struct space *
space_find_by_no(u32 space_no)
{
	struct space *space = space_cache_get(space_no);
	if (likely(space != NULL && space->state == SPACE_CONFIGURED))
		return space;

	/* Space is not found */
	assert (space_no != BOX_SYSSPACE_NO);
	assert (space_no != BOX_SYSINDEX_NO);

	char name_buf[11];
	sprintf(name_buf, "%u", space_no);
	tnt_raise(ClientError, :ER_NO_SUCH_SPACE, name_buf);
}

struct space *
space_find_by_name(const void *name)
{
	struct space *sysspace_space = space_find_by_no(BOX_SYSSPACE_NO);

	/* Try to lookup the space metadata by space name */
	Index *sysspace_pk = index_find_by_no(sysspace_space, 1);
	struct tuple *space_tuple = [sysspace_pk findByKey: name :1];
	if (space_tuple == NULL) {
		const void *name2 = name;
		u32 name_len = load_varint32(&name2);
		char name_buf[BOX_SPACE_NAME_MAXLEN];
		memcpy(name_buf, name2, name_len);
		name_buf[name_len] = 0;
		tnt_raise(ClientError, :ER_NO_SUCH_SPACE, name_buf);
	}

	u32 space_no;
	load_field_u32(space_tuple->data, &space_no);
	return space_find_by_no(space_no);
}

Index *
index_find_by_no(struct space *sp, u32 index_no)
{
	if (index_no >= BOX_INDEX_MAX || sp->index[index_no] == NULL)
		tnt_raise(LoggedError, :ER_NO_SUCH_INDEX, index_no,
			  space_n(sp));
	return sp->index[index_no];
}

size_t
space_size(struct space *sp)
{
//	assert (sp->index[0].state == INDEX_BUILT);
	return (sp->index[0] != NULL) ? [sp->index[0] size] : 0;
}

struct tuple *
space_replace(struct space *sp, struct tuple *old_tuple,
	      struct tuple *new_tuple, enum dup_replace_mode mode)
{
	assert (old_tuple != NULL || new_tuple != NULL);

	if (unlikely(sp->state != SPACE_CONFIGURED)) {
		raise_meta_error("space_no=%u: "
				 "space is locked", sp->no);
	}

	if (sp->index[0] == NULL) {
		raise_meta_error("space_no=%u: "
				 "primary key is not configured", sp->no);
	}

	/*
	 * Check tuples
	 */
	if (old_tuple) {
		space_validate_tuple(sp, old_tuple);
	}

	if (new_tuple) {
		space_validate_tuple(sp, new_tuple);
	}

	if (unlikely(sp->shadow != NULL)) {
		if (new_tuple) {
			space_validate_tuple(sp->shadow, old_tuple);
		}

		if (new_tuple) {
			space_validate_tuple(sp->shadow, new_tuple);
		}
	}

	u32 index_no = 0;
	u32 index_no_shadow = 0;
	u32 index_count = (secondary_indexes_enabled) ? BOX_INDEX_MAX : 1;

	@try {
		/*
		 * Update the primary key
		 */
		assert (sp->index[0] != NULL);
		Index *pk = sp->index[0];
		assert(pk->key_def->is_unique);

		/*
		 * If old_tuple is not NULL, the index
		 * has to find and delete it, or raise an
		 * error.
		 */
		old_tuple = [pk replace: old_tuple :new_tuple :mode];
		assert(old_tuple || new_tuple);
		index_no++;

		/*
		 * Update secondary keys
		 */
		for (; index_no < index_count; index_no++) {
			if (sp->index[index_no] == NULL)
				continue;

			assert (!sp->index_is_shared[index_no]);
			Index *index = sp->index[index_no];
			[index replace: old_tuple :new_tuple :DUP_INSERT];
		}

		if (likely(sp->shadow == NULL))
			return old_tuple;

		/*
		 * Update shadow copy
		 */
		assert (sp->shadow->index[0] != NULL);
		for (; index_no_shadow < index_count; index_no_shadow++) {
			if (sp->shadow->index[index_no_shadow] == NULL)
				continue;

			if (sp->shadow->index_is_shared[index_no_shadow])
				continue;

			Index *index = sp->shadow->index[index_no_shadow];
			[index replace: old_tuple :new_tuple :DUP_INSERT];
		}

		return old_tuple;
	} @catch (tnt_Exception *e) {
		/*
		 * Rollback all changes
		 */

		@try {
			for (; index_no > 0; index_no--) {
				Index *index = sp->index[index_no - 1];
				[index replace: new_tuple: old_tuple:
						DUP_INSERT];
			}

			for (; index_no_shadow > 0; index_no_shadow--) {
				Index *index = sp->index[index_no_shadow - 1];
				[index replace: new_tuple: old_tuple:
						DUP_INSERT];
			}
		} @catch (tnt_Exception *e) {
			[e log];
			panic("space_replace rollback failed");
		}

		@throw;
	}
}

void
space_validate_tuple(struct space *sp, struct tuple *new_tuple)
{
	/* Check to see if the tuple has a sufficient number of fields. */
	if (new_tuple->field_count < sp->max_fieldno)
		tnt_raise(IllegalParams,
			  :"tuple must have all indexed fields");

	if (sp->arity > 0 && sp->arity != new_tuple->field_count) {
		tnt_raise(IllegalParams,
			  :"tuple field count must match space cardinality");
	}

	/* Sweep through the tuple and check the field sizes. */
	const u8 *data = new_tuple->data;
	for (u32 f = 0; f < sp->max_fieldno; ++f) {
		/* Get the size of the current field and advance. */
		u32 len = load_varint32((const void **) &data);
		data += len;
		/*
		 * Check fixed size fields (NUM and NUM64) and
		 * skip undefined size fields (STRING and UNKNOWN).
		 */
		if (sp->field_types[f] == NUM) {
			if (len != sizeof(u32))
				tnt_raise(ClientError, :ER_KEY_FIELD_TYPE,
					  "u32");
		} else if (sp->field_types[f] == NUM64) {
			if (len != sizeof(u64))
				tnt_raise(ClientError, :ER_KEY_FIELD_TYPE,
					  "u64");
		}
	}
}

void
space_recovery_begin_build(void)
{
	struct space *sysspace = space_find_by_no(BOX_SYSSPACE_NO);

	Index *sysspace_pk = index_find_by_no(sysspace, 0);
	struct iterator *it = [sysspace_pk allocIterator];
	@try {
		struct tuple *tuple;
		[sysspace_pk initIterator: it :ITER_ALL :NULL :0];
		while ((tuple = it->next(it)) != NULL) {
			const void *d = tuple->data;
			u32 space_no;
			load_field_u32(d, &space_no);
			struct space *space = space_find_by_no(space_no);

			if (space_no == BOX_SYSSPACE_NO ||
			    space_no == BOX_SYSINDEX_NO)
				continue;

			say_debug("Space %u: beginBuild", space_no);
			Index *space_pk = index_find_by_no(space, 0);
			[space_pk beginBuild];
		}
	} @finally {
		it->free(it);
	}
}

void
space_recovery_end_build(void)
{
	struct space *sysspace = space_find_by_no(BOX_SYSSPACE_NO);

	Index *sysspace_pk = index_find_by_no(sysspace, 0);
	struct iterator *it = [sysspace_pk allocIterator];
	@try {
		[sysspace_pk initIterator: it :ITER_ALL :NULL :0];

		struct tuple *tuple = NULL;
		while ((tuple = it->next(it)) != NULL) {
			const void *d = tuple->data;
			u32 space_no;
			load_field_u32(d, &space_no);
			struct space *space = space_find_by_no(space_no);

			if (space_no == BOX_SYSSPACE_NO ||
			    space_no == BOX_SYSINDEX_NO)
				continue;

			assert (space->state == SPACE_CONFIGURED);
			assert (space->shadow == NULL);

			say_debug("Space %u: endBuild", space_no);
			Index *space_pk = index_find_by_no(space, 0);
			[space_pk endBuild];
		}
	} @finally {
		it->free(it);
	}
}

void
space_recovery_next(struct space *space, struct tuple *tuple)
{
	/* Check to see if the tuple has a sufficient number of fields. */
	space_validate_tuple(space, tuple);

	Index *pk = index_find_by_no(space, 0);
	if (space->no == BOX_SYSSPACE_NO || space->no == BOX_SYSINDEX_NO) {
		if (space->no == BOX_SYSSPACE_NO) {
			space_sysspace_before(NULL, space, NULL, tuple);
		} else {
			space_sysindex_before(NULL, space, NULL, tuple);
		}
		struct tuple *old;
		old = [pk replace :NULL :tuple :DUP_REPLACE_OR_INSERT];
		if (old != NULL) {
			/* an old entry from the configuration was replaced */
			tuple_ref(old, -1);
		}
		if (space->no == BOX_SYSSPACE_NO) {
			space_sysspace_commit(NULL, space, NULL, tuple);
		} else {
			space_sysindex_commit(NULL, space, NULL, tuple);
		}
	} else {
		[pk buildNext: tuple];
	}

	tuple_ref(tuple, 1);
}

void
space_free(void)
{
	mh_int_t i;
	mh_foreach(spaces_by_no, i) {
		struct space *space = mh_i32ptr_node(spaces_by_no, i)->val;
		space_delete(space);
	}
}

/**
 * @brief Create a new meta tuple based on confetti space configuration
 */
static struct tuple *
space_config_convert_space(tarantool_cfg_space *cfg_space, u32 space_no)
{
	/* TODO: create space_meta first */

	u32 max_fieldno = 0;
	for (u32 i = 0; cfg_space->index[i] != NULL; ++i) {
		typeof(cfg_space->index[i]) cfg_index = cfg_space->index[i];

		/* Calculate key part count and maximal field number. */
		for (u32 part = 0; cfg_index->key_field[part] != NULL; ++part) {
			typeof(cfg_index->key_field[part]) cfg_key =
					cfg_index->key_field[part];

			if (cfg_key->fieldno == -1) {
				/* last filled key reached */
				break;
			}

			max_fieldno = MAX(max_fieldno, cfg_key->fieldno + 1);
		}
	}

	assert(max_fieldno > 0);

	enum field_data_type *field_types =
			palloc(fiber->gc_pool, max_fieldno * sizeof(u32));
	memset(field_types, 0, max_fieldno * sizeof(u32));

	u32 defined_fieldno = 0;
	for (u32 i = 0; cfg_space->index[i] != NULL; ++i) {
		typeof(cfg_space->index[i]) cfg_index = cfg_space->index[i];

		/* Calculate key part count and maximal field number. */
		for (u32 part = 0; cfg_index->key_field[part] != NULL; ++part) {
			typeof(cfg_index->key_field[part]) cfg_key =
					cfg_index->key_field[part];

			if (cfg_key->fieldno == -1) {
				/* last filled key reached */
				break;
			}

			enum field_data_type t =  STR2ENUM(field_data_type,
							   cfg_key->type);
			if (field_types[cfg_key->fieldno] == t)
				continue;

			assert (field_types[cfg_key->fieldno] == UNKNOWN);
			field_types[cfg_key->fieldno] = t;
			defined_fieldno++;
		}
	}

	char name_buf[11];
	sprintf(name_buf, "%u", space_no);
	size_t name_len = strlen(name_buf);

	size_t bsize = varint32_sizeof(name_len) + name_len +
		       (varint32_sizeof(sizeof(u32)) + sizeof(u32)) *
		       (3 + 2 * defined_fieldno);

	struct tuple *tuple = tuple_alloc(bsize);
	assert (tuple != NULL);
	tuple->field_count = 1 + 3 + 2 * defined_fieldno;

	void *d = tuple->data;
	/* space_no */
	d = save_field_u32(d, space_no);

	/* name */
	d = save_field_str(d, name_buf, name_len);

	/* arity */
	u32 arity = (cfg_space->cardinality != -1) ? cfg_space->cardinality : 0;
	d = save_field_u32(d, arity);

	u32 flags = 0;
	d = save_field_u32(d, flags);

	for (u32 fieldno = 0; fieldno < max_fieldno; fieldno++) {
		u32 type = field_types[fieldno];
		if (type == UNKNOWN)
			continue;

		d = save_field_u32(d, fieldno);
		d = save_field_u32(d, type);
		defined_fieldno--;
	}

	assert (defined_fieldno == 0);
	assert (tuple->data + tuple->bsize == d);

#if defined(DEBUG)
	struct tbuf *out = tbuf_new(fiber->gc_pool);
	tuple_print(out, tuple->field_count, tuple->data);
	say_debug("Space %u meta: %.*s",
		  space_no, (int) out->size, tbuf_str(out));
#endif /* defined(DEBUG) */

	return tuple;
}

/**
 * @brief Create a new meta tuple based on confetti index configuration
 */
static struct tuple *
space_config_convert_index(tarantool_cfg_space_index *cfg_index,
			   u32 space_no, u32 index_no)
{
	/* TODO: create index_meta first */

	u32 defined_fieldno = 0;
	/* Calculate key part count and maximal field number. */
	for (u32 part = 0; cfg_index->key_field[part] != NULL; ++part) {
		typeof(cfg_index->key_field[part]) cfg_key =
				cfg_index->key_field[part];

		if (cfg_key->fieldno == -1) {
			/* last filled key reached */
			break;
		}

		defined_fieldno++;
	}

	assert(defined_fieldno > 0);

	char name_buf[11];
	if (index_no != 0) {
		sprintf(name_buf, "%u", index_no);
	} else {
		strcpy(name_buf, "pk");
	}
	size_t name_len = strlen(name_buf);

	size_t bsize = varint32_sizeof(name_len) + name_len +
		       (varint32_sizeof(sizeof(u32)) + sizeof(u32)) *
		       (4 + defined_fieldno);

	struct tuple *tuple = tuple_alloc(bsize);
	assert (tuple != NULL);
	tuple->field_count = 1 + 4 + defined_fieldno;

	void *d = tuple->data;
	/* space_no */
	d = save_field_u32(d, space_no);

	/* index_no */
	d = save_field_u32(d, index_no);

	/* name */
	d = save_field_str(d, name_buf, name_len);

	/* type */
	u32 type = STR2ENUM(index_type, cfg_index->type);
	assert (type < index_type_MAX);
	d = save_field_u32(d, type);

	/* unique */
	u32 unique = (cfg_index->unique) ? 1 : 0;
	d = save_field_u32(d, unique);

	for (u32 part = 0; cfg_index->key_field[part] != NULL; ++part) {
		typeof(cfg_index->key_field[part]) cfg_key =
				cfg_index->key_field[part];

		if (cfg_key->fieldno == -1) {
			/* last filled key reached */
			break;
		}

		u32 fieldno = cfg_key->fieldno;
		assert (fieldno < BOX_FIELD_MAX);
		d = save_field_u32(d, fieldno);

		defined_fieldno--;
	}

	assert (defined_fieldno == 0);
	assert (tuple->data + tuple->bsize == d);

#if defined(DEBUG)
	struct tbuf *out = tbuf_new(fiber->gc_pool);
	tuple_print(out, tuple->field_count, tuple->data);
	say_debug("Space %u index %u meta: %.*s",
		  space_no, index_no, (int) out->size, tbuf_str(out));
#endif /* defined(DEBUG) */

	return tuple;
}

static struct tuple *
space_config_convert_space_memcached(u32 memcached_space)
{
	/* TODO: create space_meta first */

	const char *name = "memcached";
	u32 name_len = strlen(name);

	u32 defined_fieldno = 3;
	size_t bsize = varint32_sizeof(name_len) + name_len +
		       (varint32_sizeof(sizeof(u32)) + sizeof(u32)) *
		       (3 + 2 * defined_fieldno);

	struct tuple *tuple = tuple_alloc(bsize);
	assert (tuple != NULL);
	tuple->field_count = 1 + 3 + 2 * defined_fieldno;

	void *d = tuple->data;
	/* space_no */
	d = save_field_u32(d, memcached_space);

	/* name */
	d = save_field_str(d, name, name_len);

	/* arity */
	u32 arity = 4;
	d = save_field_u32(d, arity);

	/* flags */
	u32 flags = 0;
	d = save_field_u32(d, flags);

	u32 field_no = 0;
	u32 field_type = STRING;
	d = save_field_u32(d, field_no);
	d = save_field_u32(d, field_type);

	field_no = 2;
	field_type = STRING;
	d = save_field_u32(d, field_no);
	d = save_field_u32(d, field_type);

	field_no = 3;
	field_type = STRING;
	d = save_field_u32(d, field_no);
	d = save_field_u32(d, field_type);

	assert (tuple->data + tuple->bsize == d);
#if defined(DEBUG)
	struct tbuf *out = tbuf_new(fiber->gc_pool);
	tuple_print(out, tuple->field_count, tuple->data);
	say_debug("Space %u meta: %.*s",
		  memcached_space, (int) out->size, tbuf_str(out));
#endif /* defined(DEBUG) */

	return tuple;
}


static struct tuple *
space_config_convert_index_memcached(u32 memcached_space)
{
	/* TODO: create index_meta first */

	static const char *name = "pk";

	u32 name_len = strlen(name);

	u32 defined_fieldno = 1;
	size_t bsize = varint32_sizeof(name_len) + name_len +
		       (varint32_sizeof(sizeof(u32)) + sizeof(u32)) *
		       (4 + defined_fieldno);

	struct tuple *tuple = tuple_alloc(bsize);
	assert (tuple != NULL);
	tuple->field_count = 1 + 4 + defined_fieldno;

	void *d = tuple->data;
	/* space_no */
	d = save_field_u32(d, memcached_space);

	/* index_no */
	u32 index_no = 0;
	d = save_field_u32(d, index_no);

	/* name */
	d = save_field_str(d, name, name_len);

	/* type */
	u32 type = HASH;
	d = save_field_u32(d, type);

	/* is_unique */
	u32 is_unique = 1;
	d = save_field_u32(d, is_unique);

	u32 field_no = 0;
	d = save_field_u32(d, field_no);

	assert (tuple->data + tuple->bsize == d);
#if defined(DEBUG)
	struct tbuf *out = tbuf_new(fiber->gc_pool);
	tuple_print(out, tuple->field_count, tuple->data);
	say_debug("Space %u index %u meta: %.*s",
		  memcached_space, 0, (int) out->size, tbuf_str(out));
#endif /* defined(DEBUG) */

	return tuple;
}

static void
space_config_convert(void)
{
	struct space *sysspace = space_find_by_no(BOX_SYSSPACE_NO);
	struct space *sysindex = space_find_by_no(BOX_SYSINDEX_NO);

	/* exit if no spaces are configured */
	if (cfg.space == NULL) {
		return;
	}

	out_warning(0,
		    "Starting from version 1.4.9 space configuration is "
		    "stored in %s and %s meta spaces and 'space' "
		    "section in tarantool.cfg is no longer necessary.\n"

		    "Your current space configuration was automatically "
		    "imported at startup. Please save a snapshot and remove "
		    "'space' section from the configuration file to remove "
		    "this warning. ",
		    BOX_SYSSPACE_NAME, BOX_SYSINDEX_NAME);

	struct tuple *meta = NULL;
	@try {
		/* fill box spaces */
		for (u32 i = 0; cfg.space[i] != NULL; ++i) {
			tarantool_cfg_space *cfg_space = cfg.space[i];

			if (!CNF_STRUCT_DEFINED(cfg_space) || !cfg_space->enabled)
				continue;

			assert(cfg.memcached_port == 0 || i != cfg.memcached_space);
			meta = space_config_convert_space(cfg_space, i);
			space_recovery_next(sysspace, meta);
			meta = NULL;

			for (u32 j = 0; cfg_space->index[j] != NULL; ++j) {
				meta = space_config_convert_index(
						cfg_space->index[j], i, j);
				space_recovery_next(sysindex, meta);
				meta = NULL;
			}
		}

		if (cfg.memcached_port != 0) {
			meta = space_config_convert_space_memcached(
						cfg.memcached_space);
			space_recovery_next(sysspace, meta);
			meta = NULL;

			meta = space_config_convert_index_memcached(
						cfg.memcached_space);
			space_recovery_next(sysindex, meta);
			meta = NULL;
		}
	} @catch(tnt_Exception *e) {
		if (meta != NULL)  {
			tuple_free(meta);
		}

		@throw;
	}
}

void
space_init(void)
{
	spaces_by_no = mh_i32ptr_new();

	/* configure system spaces */
	space_init_system();

	/* cconvert configuration */
	space_config_convert();
}

void
space_foreach(void (*func)(struct space *sp, void *udata), void *udata)
{
	mh_int_t i;
	mh_foreach(spaces_by_no, i) {
		struct space *space = mh_i32ptr_node(spaces_by_no, i)->val;
		if (space->state != SPACE_CONFIGURED)
			continue;
		func(space, udata);
	}
}

void
build_secondary_indexes(void)
{
	assert(primary_indexes_enabled == true);
	assert(secondary_indexes_enabled == false);

	mh_int_t i;
	mh_foreach(spaces_by_no, i) {
		u32 space_no = mh_i32ptr_node(spaces_by_no, i)->key;

		say_info("Space %u: begin building secondary keys...",
			 space_no);
		struct space *space = space_find_by_no(space_no);
		assert (space->state == SPACE_CONFIGURED);
		assert (space->shadow == NULL);

		Index *pk = index_find_by_no(space, 0);
		for (u32 j = 1; j < BOX_INDEX_MAX; j++) {
			if (space->index[j] == NULL)
				continue;

			Index *index = space->index[j];
			[index build: pk];
		}

		say_info("Space %u: end building secondary keys",
			 space->no);
	}

	/* enable secondary indexes now */
	secondary_indexes_enabled = true;
}

int
check_spaces(struct tarantool_cfg *conf)
{
	/* exit if no spaces are configured */
	if (conf->space == NULL) {
		return 0;
	}

	for (size_t i = 0; conf->space[i] != NULL; ++i) {
		typeof(conf->space[i]) space = conf->space[i];

		if (i >= BOX_SPACE_MAX) {
			out_warning(0, "(space = %zu) invalid id, (maximum=%u)",
				    i, BOX_SPACE_MAX);
			return -1;
		}

		if (!CNF_STRUCT_DEFINED(space)) {
			/* space undefined, skip it */
			continue;
		}

		if (!space->enabled) {
			/* space disabled, skip it */
			continue;
		}

		if (conf->memcached_port && i == conf->memcached_space) {
			out_warning(0, "Space %zu is already used as "
				    "memcached_space.", i);
			return -1;
		}

		/* at least one index in space must be defined
		 * */
		if (space->index == NULL) {
			out_warning(0, "(space = %zu) "
				    "at least one index must be defined", i);
			return -1;
		}

		if (space->estimated_rows != 0) {
			out_warning(0, "Space %zu: estimated_rows is ignored",
				    i);
		}

		u32 max_key_fieldno = 0;

		/* check spaces indexes */
		for (size_t j = 0; space->index[j] != NULL; ++j) {
			typeof(space->index[j]) index = space->index[j];
			u32 key_part_count = 0;
			enum index_type index_type;

			/* check index bound */
			if (j >= BOX_INDEX_MAX) {
				/* maximum index in space reached */
				out_warning(0, "(space = %zu index = %zu) "
					    "too many indexed (%u maximum)", i, j, BOX_INDEX_MAX);
				return -1;
			}

			/* at least one key in index must be defined */
			if (index->key_field == NULL) {
				out_warning(0, "(space = %zu index = %zu) "
					    "at least one field must be defined", i, j);
				return -1;
			}

			/* check unique property */
			if (index->unique == -1) {
				/* unique property undefined */
				out_warning(0, "(space = %zu index = %zu) "
					    "unique property is undefined", i, j);
			}

			for (size_t k = 0; index->key_field[k] != NULL; ++k) {
				typeof(index->key_field[k]) key = index->key_field[k];

				if (key->fieldno == -1) {
					/* last key reached */
					break;
				}

				if (key->fieldno >= BOX_FIELD_MAX) {
					/* maximum index in space reached */
					out_warning(0, "(space = %zu index = %zu) "
						    "invalid field number (%u maximum)",
						    i, j, BOX_FIELD_MAX);
					return -1;
				}

				/* key must has valid type */
				if (STR2ENUM(field_data_type, key->type) == field_data_type_MAX) {
					out_warning(0, "(space = %zu index = %zu) "
						    "unknown field data type: `%s'", i, j, key->type);
					return -1;
				}

				if (max_key_fieldno < key->fieldno + 1) {
					max_key_fieldno = key->fieldno + 1;
				}

				++key_part_count;
			}

			/* Check key part count. */
			if (key_part_count == 0) {
				out_warning(0, "(space = %zu index = %zu) "
					    "at least one field must be defined", i, j);
				return -1;
			}

			index_type = STR2ENUM(index_type, index->type);

			/* check index type */
			if (index_type == index_type_MAX) {
				out_warning(0, "(space = %zu index = %zu) "
					    "unknown index type '%s'", i, j, index->type);
				return -1;
			}

			/* First index must be unique. */
			if (j == 0 && index->unique == false) {
				out_warning(0, "(space = %zu) space first index must be unique", i);
				return -1;
			}

			switch (index_type) {
			case HASH:
				/* check hash index */
				/* hash index must has single-field key */
				if (key_part_count != 1) {
					out_warning(0, "(space = %zu index = %zu) "
						    "hash index must has a single-field key", i, j);
					return -1;
				}
				/* hash index must be unique */
				if (!index->unique) {
					out_warning(0, "(space = %zu index = %zu) "
						    "hash index must be unique", i, j);
					return -1;
				}
				break;
			case TREE:
				/* extra check for tree index not needed */
				break;
			default:
				assert(false);
			}
		}

		/* Check for index field type conflicts */
		if (max_key_fieldno > 0) {
			char *types = alloca(max_key_fieldno);
			memset(types, 0, max_key_fieldno);
			for (size_t j = 0; space->index[j] != NULL; ++j) {
				typeof(space->index[j]) index = space->index[j];
				for (size_t k = 0; index->key_field[k] != NULL; ++k) {
					typeof(index->key_field[k]) key = index->key_field[k];
					if (key->fieldno == -1)
						break;

					u32 f = key->fieldno;
					enum field_data_type t = STR2ENUM(field_data_type, key->type);
					assert(t != field_data_type_MAX);
					if (types[f] != t) {
						if (types[f] == UNKNOWN) {
							types[f] = t;
						} else {
							out_warning(0, "(space = %zu fieldno = %zu) "
								    "index field type mismatch", i, f);
							return -1;
						}
					}
				}

			}
		}
	}

	return 0;
}

