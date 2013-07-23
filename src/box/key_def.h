#ifndef TARANTOOL_BOX_KEY_DEF_H_INCLUDED
#define TARANTOOL_BOX_KEY_DEF_H_INCLUDED
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
#include "tarantool/util.h"
/*
 * Possible field data types. Can't use STRS/ENUM macros for them,
 * since there is a mismatch between enum name (STRING) and type
 * name literal ("STR"). STR is already used as Objective C type.
 */
enum field_type { UNKNOWN = 0, NUM, NUM64, STRING, field_type_MAX };
extern const char *field_type_strs[];

static inline uint32_t
field_type_maxlen(enum field_type type)
{
	static const uint32_t maxlen[] =
		{ UINT32_MAX, 4, 8, UINT32_MAX, UINT32_MAX };
	return maxlen[type];
}

#define INDEX_TYPE(_)                                               \
	_(HASH,    0)       /* HASH Index  */                       \
	_(TREE,    1)       /* TREE Index  */                       \
	_(BITSET,  2)       /* BITSET Index  */                     \

ENUM(index_type, INDEX_TYPE);
extern const char *index_type_strs[];

/** Descriptor of a single part in a multipart key. */
struct key_part {
	uint32_t fieldno;
	enum field_type type;
};

/* Descriptor of a multipart key. */
struct key_def {
	/** Ordinal index number in the index array. */
	uint32_t id;
	/** The size of the 'parts' array. */
	uint32_t part_count;
	/** Description of parts of a multipart index. */
	struct key_part *parts;
	/** Index type. */
	enum index_type type;
	/** Is this key unique. */
	bool is_unique;
};

/** Initialize a pre-allocated key_def. */
void
key_def_create(struct key_def *def, uint32_t id,
	       enum index_type type, bool is_unique,
	       uint32_t part_count);

/**
 * Set a single key part in a key def.
 * @pre part_no < part_count
 */
static inline void
key_def_set_part(struct key_def *def, uint32_t part_no,
		 uint32_t fieldno, enum field_type type)
{
	assert(part_no < def->part_count);
	def->parts[part_no].fieldno = fieldno;
	def->parts[part_no].type = type;
}

void
key_def_destroy(struct key_def *def);

/** Add a key to the list of keys. */
void
key_list_add_key(struct key_def **key_list, uint32_t *key_count,
		 struct key_def *key);

/** Space metadata. */
struct space_def {
	/** Space id. */
	uint32_t id;
	/**
	 * If not set (is 0), any tuple in the
	 * space can have any number of fields.
	 * If set, each tuple
	 * must have exactly this many fields.
	 */
	uint32_t arity;
};

#endif /* TARANTOOL_BOX_KEY_DEF_H_INCLUDED */
