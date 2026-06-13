-- nexus/serialize.lua
-- Player state serialization and deserialization.
-- This captures everything that needs to survive a cross-server transfer.

nexus.serialize = {}

-- Capture a player's inventory into a serializable table.
-- Returns a table mapping list names to { size = N, slots = { ["1"] = itemdata, ... } }
function nexus.serialize.capture_inventory(player)
    local inv = player:get_inventory()
    local result = {}

    for listname, list in pairs(inv:get_lists()) do
        local size = inv:get_size(listname)
        local slots = {}
        for i = 1, size do
            local stack = inv:get_stack(listname, i)
            if not stack:is_empty() then
                local entry = {
                    name = stack:get_name(),
                    count = stack:get_count(),
                    wear = stack:get_wear(),
                }
                -- Capture item metadata if present
                local meta = stack:get_meta()
                local meta_fields = meta:to_table().fields
                if next(meta_fields) then
                    entry.meta = meta_fields
                end
                slots[tostring(i)] = entry
            end
        end
        result[listname] = { size = size, slots = slots }
    end

    return result
end

-- Restore a player's inventory from a serialized table.
-- Clears existing inventory first. Handles list mismatches gracefully
-- (lists that don't exist on this server are skipped with a warning).
function nexus.serialize.restore_inventory(player, inv_data)
    local inv = player:get_inventory()

    -- Clear existing inventory
    for listname in pairs(inv:get_lists()) do
        inv:set_list(listname, {})
    end

    -- Restore each list
    for listname, list_data in pairs(inv_data) do
        local current_size = inv:get_size(listname)

        if current_size == 0 then
            -- This list doesn't exist on this server (mod mismatch).
            -- Items in it are lost — this is documented behavior.
            core.log("warning", "[nexus] inventory list '" .. listname ..
                "' not found on this galaxy, skipping " ..
                nexus.serialize.count_items(list_data) .. " items")
        else
            -- Resize if origin had a larger list
            if list_data.size > current_size then
                inv:set_size(listname, list_data.size)
            end

            for slot_str, item_data in pairs(list_data.slots) do
                local slot = tonumber(slot_str)
                local stack = ItemStack(item_data)
                -- Restore item metadata
                if item_data.meta then
                    local meta = stack:get_meta()
                    for key, value in pairs(item_data.meta) do
                        meta:set_string(key, value)
                    end
                end
                inv:set_stack(listname, slot, stack)
            end
        end
    end
end

-- Capture player metadata (the key-value store on the player object).
function nexus.serialize.capture_player_meta(player)
    local meta = player:get_meta()
    local meta_table = meta:to_table()
    return meta_table.fields or {}
end

-- Restore player metadata from a serialized table.
function nexus.serialize.restore_player_meta(player, meta_data)
    local meta = player:get_meta()
    -- Clear existing custom meta (but preserve engine-internal keys)
    local existing = meta:to_table().fields or {}
    for key in pairs(existing) do
        -- Don't clear keys that start with underscore (engine-internal)
        if not key:match("^_") then
            meta:set_string(key, "")
        end
    end
    -- Set new values
    for key, value in pairs(meta_data) do
        meta:set_string(key, value)
    end
end

-- Capture core player attributes (HP, breath).
function nexus.serialize.capture_core(player)
    return {
        hp = player:get_hp(),
        breath = player:get_breath(),
    }
end

-- Restore core player attributes.
function nexus.serialize.restore_core(player, core_data)
    if core_data.hp then
        player:set_hp(core_data.hp)
    end
    if core_data.breath then
        player:set_breath(core_data.breath)
    end
end

-- Helper: count total items in a serialized list (for logging)
function nexus.serialize.count_items(list_data)
    local count = 0
    for _ in pairs(list_data.slots or {}) do
        count = count + 1
    end
    return count
end
