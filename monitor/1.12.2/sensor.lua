-- Sensor for CC:Tweaked 1.89.2 (MC 1.12.2)
-- Reads one type of source (energy, items, or fluids)
-- and broadcasts data via rednet.
--
-- Each sensor computer reads ONE thing. Deploy multiple
-- sensors for multiple sources.

local VERSION = "1.0.0"

-- ══════════════════════════════════════════════════════
-- CONFIG - Edit this section
-- ══════════════════════════════════════════════════════

-- Rednet settings
local MODEM_SIDE = "top"
local CHANNEL = "monitor"         -- protocol name, must match all other programs

-- Sensor label (shows on display panels)
-- If nil, uses "Sensor #<computerID>"
local LABEL = nil

-- Update interval in seconds
local UPDATE_INTERVAL = 1

-- ── Choose ONE sensor type and fill in its config ──

-- Sensor type: "energy", "me_energy", "items", "inventory", "fluids"
local SENSOR_TYPE = "energy"

-- ── ENERGY (standard RF/FE blocks) ──
local ENERGY_CONFIG = {
    side = "left",                -- side the energy block is on
    label = "Main Battery",       -- display name for this source
    unit = "RF",                  -- unit the block reports in
    conversion = 1,               -- multiplier to convert to RF (1 if already RF)
    -- Examples:
    --   RF block:  unit = "RF",  conversion = 1
    --   EU block:  unit = "EU",  conversion = 4   (1 EU = 4 RF)
}

-- ── ME ENERGY (Applied Energistics 2 network) ──
local ME_ENERGY_CONFIG = {
    side = "left",                -- side the ME interface is on
    label = "ME Network",         -- display name
    unit = "AE",                  -- AE2 energy unit
    conversion = 2,               -- 1 AE = 2 RF
}

-- ── ITEMS (AE2 ME system) ──
local ITEMS_CONFIG = {
    side = "left",                -- side the ME interface is on
    label = "ME System",          -- display name for this source

    -- Items to track: { name, damage, label (optional) }
    -- If label is not given, uses name
    track = {
        { name = "minecraft:diamond",    damage = 0, label = "Diamond" },
        { name = "minecraft:iron_ingot", damage = 0, label = "Iron Ingot" },
        -- { name = "minecraft:dye",     damage = 2, label = "Cactus Green" },
    },
}

-- ── FLUIDS (tanks) ──
local FLUIDS_CONFIG = {
    side = "left",                -- side the tank is on
    label = "Tank",               -- display name for this source

    -- Fluids to track: { id, label (optional), hide_max (optional), custom_max (optional) }
    -- If label is not given, uses displayName from tank, then id
    -- hide_max = true   → hides capacity and percentage bar
    -- custom_max = N    → overrides reported capacity (in mB) for display
    track = {
        { id = "industrialforegoing:essence", label = "Essence" },
        -- { id = "minecraft:water", hide_max = true },
        -- { id = "minecraft:lava", custom_max = 1000000 },
    },
}

-- ── INVENTORY (chests, barrels, any standard inventory) ──
local INVENTORY_CONFIG = {
    side = "left",                -- side the inventory is on
    label = "Storage Chest",      -- display name for this source

    -- Items to track: { name, damage, label (optional) }
    -- Counts are summed across all slots matching name+damage
    -- If label is not given, uses name
    track = {
        { name = "minecraft:cobblestone", damage = 0, label = "Cobblestone" },
        -- { name = "minecraft:coal",     damage = 0, label = "Coal" },
    },
}

-- ══════════════════════════════════════════════════════
-- END OF CONFIG - No need to edit below this line
-- ══════════════════════════════════════════════════════

-- Resolve label
local sensorLabel = LABEL or ("Sensor #" .. os.getComputerID())

-- Open modem
rednet.open(MODEM_SIDE)

-- ── Reader functions ──

local function readEnergy()
    local p = peripheral.wrap(ENERGY_CONFIG.side)
    if not p then return nil end

    local stored = p.getEnergyStored()
    local max = p.getEnergyCapacity()
    local conv = ENERGY_CONFIG.conversion or 1

    return {
        type = "energy",
        source = ENERGY_CONFIG.label or "Energy",
        unit = ENERGY_CONFIG.unit or "RF",
        conversion = conv,
        stored = stored,
        storedRF = stored * conv,
        max = max,
        maxRF = max and (max * conv) or nil,
        usage = nil,
    }
end

local function readMEEnergy()
    local p = peripheral.wrap(ME_ENERGY_CONFIG.side)
    if not p then return nil end

    local stored = p.getNetworkEnergyStored()
    local usage = p.getNetworkEnergyUsage()
    local conv = ME_ENERGY_CONFIG.conversion or 2

    return {
        type = "energy",
        source = ME_ENERGY_CONFIG.label or "ME Network",
        unit = ME_ENERGY_CONFIG.unit or "AE",
        conversion = conv,
        stored = stored,
        storedRF = stored * conv,
        max = nil,      -- ME has no max capacity method
        maxRF = nil,
        usage = usage,  -- AE/tick
        usageRF = usage * conv,
    }
end

local function readItems()
    local p = peripheral.wrap(ITEMS_CONFIG.side)
    if not p then return nil end

    local allItems = p.listAvailableItems()
    local tracked = {}

    for _, track in ipairs(ITEMS_CONFIG.track) do
        local found = false
        for _, item in ipairs(allItems) do
            if item.name == track.name and item.damage == track.damage then
                table.insert(tracked, {
                    name = track.name,
                    damage = track.damage,
                    label = track.label or track.name,
                    count = item.count,
                    isCraftable = item.isCraftable,
                })
                found = true
                break
            end
        end
        -- Item not in system, report 0
        if not found then
            table.insert(tracked, {
                name = track.name,
                damage = track.damage,
                label = track.label or track.name,
                count = 0,
                isCraftable = false,
            })
        end
    end

    return {
        type = "items",
        source = ITEMS_CONFIG.label or "Items",
        items = tracked,
    }
end

local function readFluids()
    local p = peripheral.wrap(FLUIDS_CONFIG.side)
    if not p then return nil end

    local allTanks = p.getTanks()
    local tracked = {}

    for _, track in ipairs(FLUIDS_CONFIG.track) do
        local found = false
        for _, tank in ipairs(allTanks) do
            if tank.id == track.id then
                local cap = tank.capacity

                -- Apply custom_max override if set
                if track.custom_max then
                    cap = track.custom_max
                end

                -- Hide capacity if configured
                if track.hide_max then
                    cap = nil
                end

                table.insert(tracked, {
                    id = track.id,
                    label = track.label or tank.displayName or track.id,
                    amount = tank.amount,     -- in mB
                    capacity = cap,           -- in mB, nil if hidden
                })
                found = true
                break
            end
        end
        if not found then
            table.insert(tracked, {
                id = track.id,
                label = track.label or track.id,
                amount = 0,
                capacity = nil,
            })
        end
    end

    return {
        type = "fluids",
        source = FLUIDS_CONFIG.label or "Fluids",
        fluids = tracked,
    }
end

local function readInventory()
    local p = peripheral.wrap(INVENTORY_CONFIG.side)
    if not p then return nil end

    local allSlots = p.list()
    local tracked = {}

    for _, track in ipairs(INVENTORY_CONFIG.track) do
        -- Sum counts across all slots matching name+damage
        local total = 0
        for _, slot in pairs(allSlots) do
            if slot.name == track.name and slot.damage == track.damage then
                total = total + slot.count
            end
        end

        table.insert(tracked, {
            name = track.name,
            damage = track.damage,
            label = track.label or track.name,
            count = total,
            isCraftable = false,
        })
    end

    return {
        type = "items",
        source = INVENTORY_CONFIG.label or "Inventory",
        items = tracked,
    }
end

-- ── Select reader based on type ──

local readers = {
    energy    = readEnergy,
    me_energy = readMEEnergy,
    items     = readItems,
    inventory = readInventory,
    fluids    = readFluids,
}

local reader = readers[SENSOR_TYPE]
if not reader then
    print("Unknown SENSOR_TYPE: " .. tostring(SENSOR_TYPE))
    print("Valid types: energy, me_energy, items, inventory, fluids")
    return
end

-- ── Startup info ──

print("Monitor Sensor v" .. VERSION)

print("=== Sensor Started ===")
print("Label:    " .. sensorLabel)
print("Type:     " .. SENSOR_TYPE)
print("Modem:    " .. MODEM_SIDE)
print("Protocol: " .. CHANNEL)
print("")
print("Broadcasting every " .. UPDATE_INTERVAL .. "s")
print("Hold Ctrl+T to stop.")
print("")

-- ── Main loop ──

while true do
    local data = reader()

    if data then
        data.label = sensorLabel
        data.sensorID = os.getComputerID()
        data.timestamp = os.clock()

        local msg = textutils.serialize(data)
        rednet.broadcast(msg, CHANNEL)

        -- Status line
        term.setCursorPos(1, 10)
        term.clearLine()

        if data.type == "energy" then
            local val = tostring(math.floor(data.stored)) .. " " .. data.unit
            if data.usage then
                val = val .. " | Draw: " .. string.format("%.1f", data.usage) .. " " .. data.unit .. "/t"
            end
            term.write("Sent: " .. val)
        elseif data.type == "items" then
            local count = 0
            for _ in ipairs(data.items) do count = count + 1 end
            term.write("Sent: " .. count .. " items tracked")
        elseif data.type == "fluids" then
            local count = 0
            for _ in ipairs(data.fluids) do count = count + 1 end
            term.write("Sent: " .. count .. " fluids tracked")
        end
    else
        term.setCursorPos(1, 10)
        term.clearLine()
        term.setTextColor(colors.red)
        term.write("ERROR: Cannot read peripheral!")
        term.setTextColor(colors.white)
    end

    sleep(UPDATE_INTERVAL)
end
