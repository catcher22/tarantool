ch = box.ipc.channel();
ch:is_full();
ch:is_empty();
ch:get(.1);
ch:put();
ch:put('test');
ch:get();
ch:get('wrong timeout');
ch:get(-10);
ch:put(234);
ch:put(345, .5);
ch:is_full();
ch:is_empty();
buffer = {};
tfbr = box.fiber.create(
    function()
        box.fiber.detach()
        while true do
            table.insert(buffer, ch:get())
        end
    end
);
box.fiber.resume(tfbr);
for i = 1, 10 do
    print(i, ' : ', ch:put(i, 0.1))
end;
ch:has_readers();
ch:has_writers();
box.fiber.cancel(tfbr);

ch:has_readers();
ch:has_writers();
ch:put(box.info.pid);
ch:is_full();
ch:is_empty();
ch:get(box.info.pid) == box.info.pid;
for i, v in pairs(buffer) do
    print(v)
end;

ch:is_empty();
ch:broadcast();
ch:broadcast(123);
ch:get();

ch:is_full();
ch:is_empty();
tfbr = box.fiber.create(
    function()
        box.fiber.detach()
        while true do
            local v = ch:get()
            table.insert(buffer, 'tfbr  - ' .. tostring(v))
        end
    end
);
box.fiber.resume(tfbr);
tfbr2 = box.fiber.create(
    function()
        box.fiber.detach()
        while true do
            local v = ch:get()
            table.insert(buffer, 'tfbr2 - ' .. tostring(v))
        end
    end
);
box.fiber.resume(tfbr2);

buffer = {};

for i, v in pairs(buffer) do
    print(' - ', v)
end;
ch:is_full();
ch:is_empty();
ch:put(1);
ch:put(2);
ch:put(3);
ch:put(4);
ch:put(5);
ch:broadcast('broadcast message!');
for i = 35, 45 do
    print(' - ', ch:put(i))
end;

for i, v in pairs(buffer) do
    print(' - "', v, '"')
end;
-- vim: tabstop=4 expandtab shiftwidth=4 softtabstop=4 syntax=lua
