-- box.lua (internal file)

box.flags = { BOX_RETURN_TUPLE = 0x01, BOX_ADD = 0x02, BOX_REPLACE = 0x04 }



--
--
--
function box.select_limit(space, index, offset, limit, ...)
    local key_part_count = select('#', ...)
    return box.process(17,
        box.pack('iiiiiV',
            tonumber(space),
            tonumber(index),
            tonumber(offset),
            tonumber(limit),
            1, -- key count
            key_part_count, ...))
end

--
--
--
function box.select(space, index, ...)
    return box.select_limit(space, index, 0, 4294967295, ...)
end

--
-- Select a range of tuples in a given namespace via a given
-- index. If key is NULL, starts from the beginning, otherwise
-- starts from the key.
--
function box.select_range(sno, ino, limit, ...)
    return box.net.self:select_range(sno, ino, limit, ...)
end

--
-- Select a range of tuples in a given namespace via a given
-- index in reverse order. If key is NULL, starts from the end, otherwise
-- starts from the key.
--
function box.select_reverse_range(sno, ino, limit, ...)
    return box.net.self:select_reverse_range(sno, ino, limit, ...)
end

--
-- delete can be done only by the primary key, whose
-- index is always 0. It doesn't accept compound keys
--
function box.delete(space, ...)
    local key_part_count = select('#', ...)
    return box.process(21,
        box.pack('iiV',
            tonumber(space),
            box.flags.BOX_RETURN_TUPLE,  -- flags
            key_part_count, ...))
end

-- insert or replace a tuple
function box.replace(space, ...)
    local field_count = select('#', ...)
    return box.process(13,
        box.pack('iiV',
            tonumber(space),
            box.flags.BOX_RETURN_TUPLE,  -- flags
            field_count, ...))
end

-- insert a tuple (produces an error if the tuple already exists)
function box.insert(space, ...)
    local field_count = select('#', ...)
    return box.process(13,
        box.pack('iiV',
            tonumber(space),
            bit.bor(box.flags.BOX_RETURN_TUPLE,
                box.flags.BOX_ADD),  -- flags
            field_count, ...))
end

--
function box.update(space, key, format, ...)
    local op_count = select('#', ...)/2
    return box.process(19,
        box.pack('iiVi'..format,
            tonumber(space),
            box.flags.BOX_RETURN_TUPLE,
            1, key,
            op_count,
            ...))
end

function box.dostring(s, ...)
    local chunk, message = loadstring(s)
    if chunk == nil then
        error(message, 2)
    end
    return chunk(...)
end

function box.bless_space(space)
    local index_mt = {}
    -- __len and __index
    index_mt.len = function(index) return #index.idx end
    index_mt.__newindex = function(table, index)
        return error('Attempt to modify a read-only table') end
    index_mt.__index = index_mt
    -- min and max
    index_mt.min = function(index) return index.idx:min() end
    index_mt.max = function(index) return index.idx:max() end
    index_mt.random = function(index, rnd) return index.idx:random(rnd) end
    -- iteration
    index_mt.iterator = function(index, ...)
        return index.idx:iterator(...)
    end
    --
    -- pairs/next/prev methods are provided for backward compatibility purposes only
    index_mt.pairs = function(index)
        return index.idx.next, index.idx, nil
    end
    --
    local next_compat = function(idx, iterator_type, ...)
        local arg = {...}
        if #arg == 1 and type(arg[1]) == "userdata" then
            return idx:next(...)
        else
            return idx:next(iterator_type, ...)
        end
    end
    index_mt.next = function(index, ...)
        return next_compat(index.idx, box.index.GE, ...);
    end
    index_mt.prev = function(index, ...)
        return next_compat(index.idx, box.index.LE, ...);
    end
    index_mt.next_equal = function(index, ...)
        return next_compat(index.idx, box.index.EQ, ...);
    end
    index_mt.prev_equal = function(index, ...)
        return next_compat(index.idx, box.index.REQ, ...);
    end
    -- index subtree size
    index_mt.count = function(index, ...)
        return index.idx:count(...)
    end
    --
    index_mt.select_range = function(index, limit, ...)
        local range = {}
        for v in index:iterator(box.index.GE, ...) do
            if #range >= limit then
                break
            end
            table.insert(range, v)
            iterator_state, v = index:next(iterator_state)
        end
        return unpack(range)
    end
    index_mt.select_reverse_range = function(index, limit, ...)
        local range = {}
        for v in index:iterator(box.index.LE, ...) do
            if #range >= limit then
                break
            end
            table.insert(range, v)
            iterator_state, v = index:prev(iterator_state)
        end
        return unpack(range)
    end
    --
    local space_mt = {}
    space_mt.len = function(space) return space.index[0]:len() end
    space_mt.__newindex = index_mt.__newindex
    space_mt.select = function(space, ...) return box.select(space.n, ...) end
    space_mt.select_range = function(space, ino, limit, ...)
        return space.index[ino]:select_range(limit, ...)
    end
    space_mt.select_reverse_range = function(space, ino, limit, ...)
        return space.index[ino]:select_reverse_range(limit, ...)
    end
    space_mt.select_limit = function(space, ino, offset, limit, ...)
        return box.select_limit(space.n, ino, offset, limit, ...)
    end
    space_mt.insert = function(space, ...) return box.insert(space.n, ...) end
    space_mt.update = function(space, ...) return box.update(space.n, ...) end
    space_mt.replace = function(space, ...) return box.replace(space.n, ...) end
    space_mt.delete = function(space, ...) return box.delete(space.n, ...) end
    space_mt.truncate = function(space)
        local pk = space.index[0]
        while #pk.idx > 0 do
            for t in pk:iterator() do
                local key = {};
                -- ipairs does not work because pk.key_field is zero-indexed
                for _k2, key_field in pairs(pk.key_field) do
                    table.insert(key, t[key_field.fieldno])
                end
                space:delete(unpack(key))
            end
        end
    end
    space_mt.pairs = function(space) return space.index[0]:pairs() end
    space_mt.__index = space_mt

    setmetatable(space, space_mt)
    if type(space.index) == 'table' and space.enabled then
        for j, index in pairs(space.index) do
            rawset(index, 'idx', box.index.new(space.n, j))
            setmetatable(index, index_mt)
        end
    end
end

-- User can redefine the hook
function box.on_reload_configuration()
end

require("bit")

-- vim: set et ts=4 sts
