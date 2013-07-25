#ifndef INCLUDES_TARANTOOL_LUA_H
#define INCLUDES_TARANTOOL_LUA_H
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
#include <stddef.h>
#include <inttypes.h>

struct lua_State;
struct luaL_Reg;
struct tarantool_cfg;
struct tbuf;

/*
 * Single global lua_State shared by core and modules.
 * Created with tarantool_lua_init().
 */
extern struct lua_State *tarantool_L;

/**
 * This is a callback used by tarantool_lua_init() to open
 * module-specific libraries into given Lua state.
 *
 * No return value, panics if error.
 */
void
mod_lua_init(struct lua_State *L);

void
tarantool_lua_register_type(struct lua_State *L, const char *type_name,
			    const struct luaL_Reg *methods);

/**
 * Create an instance of Lua interpreter and load it with
 * Tarantool modules.  Creates a Lua state, imports global
 * Tarantool modules, then calls mod_lua_init(), which performs
 * module-specific imports. The created state can be freed as any
 * other, with lua_close().
 *
 * @return  L on success, 0 if out of memory
 */
struct lua_State *
tarantool_lua_init();

void
tarantool_lua_close(struct lua_State *L);

/**
 * This function exists because lua_tostring does not use
 * __tostring metamethod, and this metamethod has to be used
 * if we want to print Lua userdata correctly.
 */
const char *
tarantool_lua_tostring(struct lua_State *L, int index);

/**
 * Convert Lua string, number or cdata (u64) to 64bit value
 */
uint64_t
tarantool_lua_tointeger64(struct lua_State *L, int idx);

/**
 * Make a new configuration available in Lua
 */
void
tarantool_lua_load_cfg(struct lua_State *L,
		       struct tarantool_cfg *cfg);

/**
 * Load and execute start-up file
 *
 * @param L is a Lua State.
 */
void
tarantool_lua_load_init_script(struct lua_State *L);

void
tarantool_lua(struct lua_State *L,
	      struct tbuf *out, const char *str);

/**
 * @brief Return FFI's CTypeID of given С type
 * @param L Lua State
 * @param ctypename С type name as string (e.g. "struct request" or "uint32_t")
 * @sa luaL_pushcdata
 * @sa luaL_checkcdata
 * @return FFI's CTypeID
 */
uint32_t
tarantool_lua_ctypeid(struct lua_State *L, const char *ctypename);

/**
 * @brief Allocate a new block of memory with the given size, push onto the
 * stack a new cdata of type ctypeid with the block address, and returns
 * this address. Allocated memory is a subject of GC.
 * CTypeID must be used from FFI at least once.
 * @param L Lua State
 * @param ctypeid FFI's CTypeID of this cdata
 * @param size size to allocate
 * @sa tarantool_lua_ctypeid
 * @sa luaL_checkcdata
 * @return memory associated with this cdata
 */
void *
luaL_pushcdata(struct lua_State *L, uint32_t ctypeid, uint32_t size);

/**
 * @brief Checks whether the function argument idx is a cdata
 * @param L Lua State
 * @param idx stack index
 * @param ctypeid FFI's CTypeID of this cdata
 * @param ctypename C type name as string (used only to raise errors)
 * @sa tarantool_lua_ctypeid
 * @sa luaL_pushcdata
 * @return memory associated with this cdata
 */
void *
luaL_checkcdata(struct lua_State *L, int idx, uint32_t *ctypeid,
		const char *ctypename);

/**
 * push uint64_t to Lua stack
 *
 * @param L is a Lua State
 * @param val is a value to push
 *
 */
int luaL_pushnumber64(struct lua_State *L, uint64_t val);

/**
 * show plugin statistics (for admin port)
 */
struct tbuf;
void show_plugins_stat(struct tbuf *out);

/**
 * @brief A palloc-like wrapper to allocate memory using lua_newuserdata
 * @param ctx lua_State
 * @param size a number of bytes to allocate
 * @return a pointer to the allocated memory
 */
void *
lua_region_alloc(void *ctx, size_t size);

#endif /* INCLUDES_TARANTOOL_LUA_H */
