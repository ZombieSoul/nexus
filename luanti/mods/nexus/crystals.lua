-- nexus/crystals.lua
-- Memory crystal system — addresses as physical items.
--
-- Crystals store gate addresses as item metadata. They can be inserted
-- into a gate's crystal slot to provide clickable address buttons.
--
-- Three independent security layers (all optional):
--   1. PHYSICAL — crystal is an item; can be stored, traded, stolen, lost
--   2. PIN      — "private" crystals require a PIN to activate in a gate
--   3. ENCRYPT  — per-entry: shows nickname only, address can't be copied
--
-- Copy rules:
--   - Public crystals: fully copyable (all non-encrypted entries)
--   - Private crystals: cannot be duplicated at all (prevents offline PIN cracking)
--
-- This is nexus core (gate mechanics). Crafting recipe is a content mod.

local CRYSTAL_ITEM = "nexus:resonance_crystal"
local CRYSTAL_MAX_ADDRESSES = 20

nexus.crystal = {}

-- =============================================================================
-- Crystal Data Model
-- =============================================================================
-- Crystal data is stored in item metadata as a JSON string:
-- {
--   addresses = { ["galaxy:world:gate_id"] = {label="Name", encrypted=false} },
--   private = bool,
--   pin_hash = "sha256 hash" or nil,
--   unlocked = true/false  -- runtime only, for gate session
-- }

local function get_crystal_data(stack)
    local meta = stack:get_meta()
    local raw = meta:get_string("nexus_crystal")
    if raw == "" then
        return { addresses = {}, private = false }
    end
    local data = core.parse_json(raw)
    if not data then
        return { addresses = {}, private = false }
    end
    data.addresses = data.addresses or {}
    return data
end

local function set_crystal_data(stack, data)
    local meta = stack:get_meta()
    meta:set_string("nexus_crystal", core.write_json(data))
    -- Update the item description to show count
    local count = 0
    for _ in pairs(data.addresses) do count = count + 1 end
    local label = count > 0
        and ("Resonance Crystal (" .. count .. " address" .. (count > 1 and "es" or "") .. ")")
        or "Resonance Crystal (blank)"
    meta:set_string("description", label)
end

--- Is this stack a resonance crystal?
function nexus.crystal.is_crystal(stack)
    return stack and stack:get_name() == CRYSTAL_ITEM
end

-- =============================================================================
-- Crystal Address API
-- =============================================================================

--- Get the addresses stored on a crystal.
--- @param stack ItemStack
--- @param include_encrypted bool  If false, omit encrypted entries (for copying)
--- @return table addresses  {address = {label=, encrypted=}}
function nexus.crystal.get_addresses(stack, include_encrypted)
    local data = get_crystal_data(stack)
    if not include_encrypted then
        local result = {}
        for addr, entry in pairs(data.addresses) do
            if not entry.encrypted then
                result[addr] = entry
            end
        end
        return result
    end
    return data.addresses
end

--- Save an address to a crystal.
--- @param stack ItemStack
--- @param address string  Full gate address
--- @param label string    Friendly name
--- @param encrypted bool  Hide the address string from copying?
--- @return boolean success
function nexus.crystal.save_address(stack, address, label, encrypted)
    local data = get_crystal_data(stack)
    local count = 0
    for _ in pairs(data.addresses) do count = count + 1 end
    if count >= CRYSTAL_MAX_ADDRESSES then
        return false, "Crystal is full"
    end
    data.addresses[address] = {
        label = label or address,
        encrypted = encrypted == true,
    }
    set_crystal_data(stack, data)
    return true
end

--- Is this crystal PIN-protected (private)?
function nexus.crystal.is_private(stack)
    local data = get_crystal_data(stack)
    return data.private == true
end

--- Set or change the PIN on a crystal.
function nexus.crystal.set_pin(stack, pin)
    local data = get_crystal_data(stack)
    if pin and pin ~= "" then
        data.private = true
        data.pin_hash = core.sha256(pin)
    else
        data.private = false
        data.pin_hash = nil
    end
    set_crystal_data(stack, data)
end

--- Verify a PIN against a crystal.
function nexus.crystal.verify_pin(stack, pin)
    local data = get_crystal_data(stack)
    if not data.private then return true end
    if not pin or pin == "" then return false end
    return data.pin_hash == core.sha256(pin)
end

--- Can this crystal be duplicated? (Private crystals cannot — prevents
--- offline PIN cracking on copies.)
function nexus.crystal.is_copyable(stack)
    return not nexus.crystal.is_private(stack)
end

--- Create a copy of a crystal (public entries only).
--- Returns a new ItemStack or nil if the source is private.
function nexus.crystal.copy(stack)
    if nexus.crystal.is_private(stack) then
        return nil
    end
    local new_stack = ItemStack(CRYSTAL_ITEM)
    local data = get_crystal_data(stack)
    -- Only copy non-encrypted entries
    local copy_data = { addresses = {}, private = false }
    for addr, entry in pairs(data.addresses) do
        if not entry.encrypted then
            copy_data.addresses[addr] = { label = entry.label, encrypted = false }
        end
    end
    set_crystal_data(new_stack, copy_data)
    return new_stack
end

-- =============================================================================
-- Crystal Item Registration
-- =============================================================================

core.register_craftitem(CRYSTAL_ITEM, {
    description = "Resonance Crystal (blank)",
    inventory_image = "nexus_core_crystal.png",
    groups = {nexus_crystal = 1},
    stack_max = 1,  -- each crystal is unique (has metadata)

    -- Right-click while pointing at air/empty space opens the management GUI.
    -- (When pointing at a node, that node's on_rightclick takes priority.)
    on_secondary_use = function(itemstack, player, pointed_thing)
        nexus.crystal.show_manage_gui(itemstack, player)
        return nil  -- don't consume the item
    end,
})

-- =============================================================================
-- Crystal Management GUI
-- =============================================================================
-- Right-click a crystal in hand to manage its addresses.

function nexus.crystal.show_manage_gui(itemstack, player)
    local pname = player:get_player_name()
    local data = get_crystal_data(itemstack)

    local function islot(x, y, w, h)
        if mcl_formspec and mcl_formspec.get_itemslot_bg_v4 then
            return mcl_formspec.get_itemslot_bg_v4(x, y, w, h)
        end
        return ""
    end

    local pin_text = data.private and "Private (PIN set)" or "Public (no PIN)"
    local pin_color = data.private and "#C87000" or "#7A7A7A"

    local parts = {
        "formspec_version[4]",
        "size[9,10]",
        -- No no_prepend — let Mineclonia theme apply
        "label[3,0.4;Resonance Crystal]",
        string.format("label[2.5,0.8;%s%s%s]",
            core.colorize(pin_color, ""), pin_text, ""),
    }

    -- ── Saved addresses ──
    parts[#parts+1] = "label[0.4,1.4;Saved Addresses]"

    local y = 1.8
    local count = 0
    for addr, entry in pairs(data.addresses) do
        count = count + 1
        local lock = entry.encrypted and " \226\150\160" or ""
        local label = core.formspec_escape(entry.label .. lock)
        parts[#parts+1] = string.format("label[0.5,%f;%s]", y, label)
        parts[#parts+1] = string.format(
            "button[6.5,%f;1.8,0.6;del_%d;Remove]",
            y - 0.1, count)
        y = y + 0.6
    end

    if count == 0 then
        parts[#parts+1] = "label[0.5,2.1;No saved addresses on this crystal]"
    end

    -- ── Add address ──
    parts[#parts+1] = "label[0.4,5.0;Save New Address]"
    parts[#parts+1] = "field[0.4,5.4;5,0.8;new_addr;Address;]"
    parts[#parts+1] = "field[5.6,5.4;2.8,0.8;new_label;Label;]"
    parts[#parts+1] = "checkbox[0.4,6.1;new_encrypted;Encrypt (hide address);false]"
    parts[#parts+1] = "button[4.8,6.3;3.6,0.8;add;Save Address]"

    -- ── Security ──
    parts[#parts+1] = "label[0.4,7.5;Security]"
    parts[#parts+1] = "field[0.4,7.9;4,0.8;new_pin;New PIN;]"
    parts[#parts+1] = "button[4.8,8.0;3.6,0.8;set_pin;Set / Change PIN]"
    parts[#parts+1] = "label[0.4,8.9;Private crystals require a PIN to use in gates and cannot be duplicated.]"

    core.show_formspec(pname, "nexus:crystal_manage", table.concat(parts))

    -- Store which crystal we're editing (in player meta)
    -- We can't pass the ItemStack directly through formspec, so we track
    -- the wield index
    local pmeta = player:get_meta()
    pmeta:set_string("nexus_crystal_wield_idx",
        tostring(player:get_wield_index()))
end

core.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "nexus:crystal_manage" then return end

    local pname = player:get_player_name()
    local pmeta = player:get_meta()
    local idx_str = pmeta:get_string("nexus_crystal_wield_idx")
    if idx_str == "" then return end

    local idx = tonumber(idx_str)
    local inv = player:get_inventory()
    local stack = inv:get_stack("main", idx)
    if not nexus.crystal.is_crystal(stack) then
        core.chat_send_player(pname, "[nexus] Crystal not found in hand.")
        return true
    end

    -- Safety: if somehow we have a stack > 1 (e.g. crystals obtained before
    -- stack_max=1 was enforced), split off one crystal to modify. The rest
    -- stays blank in the inventory.
    if stack:get_count() > 1 then
        local remainder = ItemStack(stack)
        remainder:set_count(stack:get_count() - 1)
        -- Clear metadata on the remainder so they're truly blank
        local rmeta = remainder:get_meta()
        rmeta:set_string("nexus_crystal", "")
        rmeta:set_string("description", "")
        inv:set_stack("main", idx, remainder)
        stack:set_count(1)
        -- The single modified crystal goes into the hand (same slot now has
        -- remainder; add the single crystal after)
        inv:add_item("main", stack)
    end

    if fields.add then
        local addr = (fields.new_addr or ""):trim()
        local label = (fields.new_label or ""):trim()
        if addr == "" then
            core.chat_send_player(pname, "[nexus] Enter an address.")
            return true
        end
        local encrypted = fields.new_encrypted == "true"
        local ok, err = nexus.crystal.save_address(stack, addr, label, encrypted)
        if ok then
            inv:set_stack("main", idx, stack)
            core.chat_send_player(pname, "[nexus] Address saved to crystal.")
            nexus.crystal.show_manage_gui(stack, player)
        else
            core.chat_send_player(pname, "[nexus] " .. (err or "Failed to save."))
        end
        return true

    elseif fields.set_pin then
        local pin = (fields.new_pin or ""):trim()
        nexus.crystal.set_pin(stack, pin)
        inv:set_stack("main", idx, stack)
        if pin ~= "" then
            core.chat_send_player(pname, "[nexus] Crystal is now private (PIN protected).")
        else
            core.chat_send_player(pname, "[nexus] PIN removed — crystal is now public.")
        end
        nexus.crystal.show_manage_gui(stack, player)
        return true
    end

    -- Handle delete buttons
    for field_name in pairs(fields) do
        local del_num = field_name:match("^del_(%d+)$")
        if del_num then
            local data = get_crystal_data(stack)
            local i = 0
            local to_remove = nil
            for addr in pairs(data.addresses) do
                i = i + 1
                if i == tonumber(del_num) then
                    to_remove = addr
                    break
                end
            end
            if to_remove then
                data.addresses[to_remove] = nil
                set_crystal_data(stack, data)
                inv:set_stack("main", idx, stack)
                core.chat_send_player(pname, "[nexus] Address removed from crystal.")
            end
            nexus.crystal.show_manage_gui(stack, player)
            return true
        end
    end

    return true
end)

-- =============================================================================
-- Gate Crystal Slot
-- =============================================================================
-- The gate base block gains a 1-slot inventory for crystals.

local GATE_CRYSTAL_SLOT = "crystal"

--- Get the crystal stack from a gate, or nil if empty.
function nexus.crystal.get_gate_crystal(pos)
    local meta = core.get_meta(pos)
    local inv = meta:get_inventory()
    if not inv:get_list(GATE_CRYSTAL_SLOT) then return nil end
    local stack = inv:get_stack(GATE_CRYSTAL_SLOT, 1)
    if stack:is_empty() then return nil end
    return stack
end

--- Track which gates have their crystal PIN-unlocked this session.
local gate_unlocked = {}

--- Is this gate's crystal PIN-unlocked (or has no PIN)?
function nexus.crystal.is_gate_unlocked(pos)
    local key = minetest.pos_to_string(pos)
    if gate_unlocked[key] then return true end
    local stack = nexus.crystal.get_gate_crystal(pos)
    if not stack then return false end
    return not nexus.crystal.is_private(stack)
end

--- Try to unlock a gate's crystal with a PIN.
function nexus.crystal.try_unlock(pos, pin)
    local stack = nexus.crystal.get_gate_crystal(pos)
    if not stack then return false, "No crystal" end
    if not nexus.crystal.is_private(stack) then
        gate_unlocked[minetest.pos_to_string(pos)] = true
        return true
    end
    if nexus.crystal.verify_pin(stack, pin) then
        gate_unlocked[minetest.pos_to_string(pos)] = true
        return true
    end
    return false, "Incorrect PIN"
end

--- Lock a gate's crystal (clear the unlock when crystal is removed).
function nexus.crystal.lock(pos)
    gate_unlocked[minetest.pos_to_string(pos)] = nil
end

--- Get dialable addresses for a gate from its crystal.
--- Returns {} if no crystal or crystal is locked.
function nexus.crystal.get_gate_addresses(pos)
    if not nexus.crystal.is_gate_unlocked(pos) then
        return {}
    end
    local stack = nexus.crystal.get_gate_crystal(pos)
    if not stack then return {} end
    return nexus.crystal.get_addresses(stack, true)
end

core.log("action", "[nexus] crystal system loaded")
