-- Data Server for CC:Tweaked 1.89.2 (MC 1.12.2)
-- Receives sensor broadcasts, stores tiered history,
-- responds to queries from display computers.
--
-- Place this on a dedicated computer. No disk drive needed,
-- data is stored on the computer's own filesystem.

local VERSION = "1.0.0"

-- ══════════════════════════════════════════════════════
-- CONFIG
-- ══════════════════════════════════════════════════════

local MODEM_SIDE = "top"
local SENSOR_CHANNEL = "monitor"      -- protocol sensors broadcast on
local QUERY_CHANNEL = "monitor_query" -- protocol displays query on

-- Data retention (how long each tier is kept)
local RETENTION = {
    raw_seconds    = 1800,    -- 30 minutes of per-second data (in memory only)
    minute_days    = 2,       -- 2 days of per-minute data
    hourly_days    = 60,      -- 60 days of per-hour data
    daily_days     = 365,     -- 1 year of per-day data
}

-- How often to write minute-tier data to disk (in seconds)
local DISK_WRITE_INTERVAL = 60

-- Data directory on filesystem
local DATA_DIR = "/data"

-- ══════════════════════════════════════════════════════
-- END OF CONFIG
-- ══════════════════════════════════════════════════════

-- ── Helpers ──

local function now()
    -- Real-world milliseconds since epoch
    return os.epoch("utc")
end

local function nowSeconds()
    return math.floor(os.epoch("utc") / 1000)
end

local function ensureDir(path)
    if not fs.exists(path) then
        fs.makeDir(path)
    end
end

local function sanitizeKey(str)
    -- Replace characters that are bad for filenames
    return str:gsub("[:/\\%.%s]", "_")
end

-- ── Resource Key Generation ──
-- Creates a unique key for each tracked resource

local function makeKey(data, subID)
    if data.type == "energy" then
        return "energy:" .. data.sensorID .. ":" .. sanitizeKey(data.source)
    elseif data.type == "items" then
        return "item:" .. data.sensorID .. ":" .. subID.name .. ":" .. subID.damage
    elseif data.type == "fluids" then
        return "fluid:" .. data.sensorID .. ":" .. subID.id
    end
    return "unknown"
end

local function keyToFilename(key)
    return sanitizeKey(key)
end

-- ── In-Memory Raw Sample Storage ──

local rawBuffers = {}   -- key -> { samples = {}, index = 0 }
local MAX_RAW = 1800    -- 30 minutes at 1/second

local function getRawBuffer(key)
    if not rawBuffers[key] then
        rawBuffers[key] = { samples = {}, index = 0 }
    end
    return rawBuffers[key]
end

local function recordRaw(key, value, ts)
    local buf = getRawBuffer(key)
    buf.index = buf.index + 1
    local idx = ((buf.index - 1) % MAX_RAW) + 1
    buf.samples[idx] = { time = ts, value = value }
end

local function getRawSamples(key, fromTime, toTime)
    local buf = rawBuffers[key]
    if not buf then return {} end

    local result = {}
    local count = math.min(buf.index, MAX_RAW)
    for i = 1, count do
        local s = buf.samples[i]
        if s and s.time >= fromTime and s.time <= toTime then
            table.insert(result, s)
        end
    end

    -- Sort by time
    table.sort(result, function(a, b) return a.time < b.time end)
    return result
end

-- ── Disk-Based Tiered Storage ──
-- Each tier: { {time=epoch_seconds, value=number}, ... }

local tierData = {
    minute = {},  -- key -> { samples }
    hourly = {},
    daily  = {},
}

local function getTierSamples(tier, key)
    if not tierData[tier][key] then
        tierData[tier][key] = {}
    end
    return tierData[tier][key]
end

local function addTierSample(tier, key, ts, value)
    local samples = getTierSamples(tier, key)
    table.insert(samples, { time = ts, value = value })
end

-- ── Aggregation Tracking ──
-- Tracks accumulation for downsampling

local minuteAccum = {}   -- key -> { sum, count, lastFlush }
local hourlyAccum = {}   -- key -> { sum, count, lastFlush }
local dailyAccum = {}    -- key -> { sum, count, lastFlush }

local function getAccum(store, key, ts)
    if not store[key] then
        store[key] = { sum = 0, count = 0, lastFlush = ts }
    end
    return store[key]
end

local function accumulate(store, key, value, ts, intervalSeconds, targetTier)
    local acc = getAccum(store, key, ts)
    acc.sum = acc.sum + value
    acc.count = acc.count + 1

    if ts - acc.lastFlush >= intervalSeconds and acc.count > 0 then
        local avg = acc.sum / acc.count
        addTierSample(targetTier, key, ts, avg)
        acc.sum = 0
        acc.count = 0
        acc.lastFlush = ts
        return true  -- flushed
    end
    return false
end

-- ── Retention Cleanup ──

local function cleanupTier(tier, maxAgeSec)
    local cutoff = nowSeconds() - maxAgeSec
    for key, samples in pairs(tierData[tier]) do
        local cleaned = {}
        for _, s in ipairs(samples) do
            if s.time >= cutoff then
                table.insert(cleaned, s)
            end
        end
        tierData[tier][key] = cleaned
    end
end

local function runCleanup()
    cleanupTier("minute", RETENTION.minute_days * 86400)
    cleanupTier("hourly", RETENTION.hourly_days * 86400)
    cleanupTier("daily",  RETENTION.daily_days  * 86400)
end

-- ── Disk I/O ──

local function saveTier(tier)
    local dir = DATA_DIR .. "/" .. tier
    ensureDir(dir)

    for key, samples in pairs(tierData[tier]) do
        if #samples > 0 then
            local path = dir .. "/" .. keyToFilename(key) .. ".dat"
            local f = fs.open(path, "w")
            if f then
                f.write(textutils.serialize(samples))
                f.close()
            end
        end
    end
end

local function loadTier(tier)
    local dir = DATA_DIR .. "/" .. tier
    if not fs.exists(dir) then return end

    local files = fs.list(dir)
    for _, filename in ipairs(files) do
        local path = dir .. "/" .. filename
        if not fs.isDir(path) then
            local f = fs.open(path, "r")
            if f then
                local content = f.readAll()
                f.close()
                local ok, data = pcall(textutils.unserialize, content)
                if ok and type(data) == "table" then
                    -- Reconstruct key from filename (strip .dat)
                    local key = filename:gsub("%.dat$", "")
                    tierData[tier][key] = data
                end
            end
        end
    end
end

local function saveAllToDisk()
    ensureDir(DATA_DIR)
    saveTier("minute")
    saveTier("hourly")
    saveTier("daily")
end

local function loadAllFromDisk()
    ensureDir(DATA_DIR)
    loadTier("minute")
    loadTier("hourly")
    loadTier("daily")
end

-- ── Resource Metadata ──
-- Stores info about each resource for displays to discover

local resourceMeta = {}  -- key -> { type, source, label, sensorID, sensorLabel, unit, ... }

local function saveMeta()
    ensureDir(DATA_DIR)
    local f = fs.open(DATA_DIR .. "/meta.dat", "w")
    if f then
        f.write(textutils.serialize(resourceMeta))
        f.close()
    end
end

local function loadMeta()
    local path = DATA_DIR .. "/meta.dat"
    if fs.exists(path) then
        local f = fs.open(path, "r")
        if f then
            local content = f.readAll()
            f.close()
            local ok, data = pcall(textutils.unserialize, content)
            if ok and type(data) == "table" then
                resourceMeta = data
            end
        end
    end
end

-- ── Process Incoming Sensor Data ──

local function processSensorData(senderID, data)
    local ts = nowSeconds()

    if data.type == "energy" then
        local key = makeKey(data)
        local fileKey = keyToFilename(key)

        -- Store metadata
        resourceMeta[fileKey] = {
            type = "energy",
            key = fileKey,
            source = data.source,
            sensorID = data.sensorID,
            sensorLabel = data.label,
            unit = data.unit,
            conversion = data.conversion,
            hasMax = data.max ~= nil,
            usage = data.usage,
            usageRF = data.usageRF,
        }

        -- Record raw (RF-converted value for consistency)
        recordRaw(fileKey, data.storedRF, ts)

        -- Aggregate to tiers
        accumulate(minuteAccum, fileKey, data.storedRF, ts, 60, "minute")
        accumulate(hourlyAccum, fileKey, data.storedRF, ts, 3600, "hourly")
        accumulate(dailyAccum, fileKey, data.storedRF, ts, 86400, "daily")

    elseif data.type == "items" then
        for _, item in ipairs(data.items) do
            local key = makeKey(data, item)
            local fileKey = keyToFilename(key)

            resourceMeta[fileKey] = {
                type = "item",
                key = fileKey,
                source = data.source,
                sensorID = data.sensorID,
                sensorLabel = data.label,
                itemName = item.name,
                itemDamage = item.damage,
                itemLabel = item.label,
                isCraftable = item.isCraftable,
            }

            recordRaw(fileKey, item.count, ts)
            accumulate(minuteAccum, fileKey, item.count, ts, 60, "minute")
            accumulate(hourlyAccum, fileKey, item.count, ts, 3600, "hourly")
            accumulate(dailyAccum, fileKey, item.count, ts, 86400, "daily")
        end

    elseif data.type == "fluids" then
        for _, fluid in ipairs(data.fluids) do
            local key = makeKey(data, fluid)
            local fileKey = keyToFilename(key)

            resourceMeta[fileKey] = {
                type = "fluid",
                key = fileKey,
                source = data.source,
                sensorID = data.sensorID,
                sensorLabel = data.label,
                fluidID = fluid.id,
                fluidLabel = fluid.label,
                capacity = fluid.capacity,
            }

            recordRaw(fileKey, fluid.amount, ts)
            accumulate(minuteAccum, fileKey, fluid.amount, ts, 60, "minute")
            accumulate(hourlyAccum, fileKey, fluid.amount, ts, 3600, "hourly")
            accumulate(dailyAccum, fileKey, fluid.amount, ts, 86400, "daily")
        end
    end
end

-- ── Handle Display Queries ──

local function handleQuery(senderID, query)
    -- Query format:
    -- { type = "query", key = "...", tier = "raw"/"minute"/"hourly"/"daily",
    --   from = epoch_seconds, to = epoch_seconds }
    -- Or:
    -- { type = "list_resources" }
    -- Or:
    -- { type = "get_meta", key = "..." }
    -- Or:
    -- { type = "get_latest", key = "..." }

    local response = nil

    if query.type == "list_resources" then
        response = {
            type = "resource_list",
            resources = resourceMeta,
        }

    elseif query.type == "get_meta" then
        response = {
            type = "meta",
            key = query.key,
            meta = resourceMeta[query.key],
        }

    elseif query.type == "get_latest" then
        -- Return latest raw sample for a resource
        local buf = rawBuffers[query.key]
        local latest = nil
        if buf and buf.index > 0 then
            local idx = ((buf.index - 1) % MAX_RAW) + 1
            latest = buf.samples[idx]
        end
        response = {
            type = "latest",
            key = query.key,
            sample = latest,
            meta = resourceMeta[query.key],
        }

    elseif query.type == "query" then
        local samples = {}
        local fromTime = query.from or 0
        local toTime = query.to or nowSeconds()

        if query.tier == "raw" then
            samples = getRawSamples(query.key, fromTime, toTime)
        else
            local tierSamples = getTierSamples(query.tier, query.key)
            for _, s in ipairs(tierSamples) do
                if s.time >= fromTime and s.time <= toTime then
                    table.insert(samples, s)
                end
            end
        end

        response = {
            type = "query_response",
            key = query.key,
            tier = query.tier,
            samples = samples,
        }

    elseif query.type == "get_delta" then
        -- Calculate delta for a resource over a time window
        local key = query.key
        local windowSeconds = query.window or 60
        local ts = nowSeconds()
        local fromTime = ts - windowSeconds

        local buf = rawBuffers[key]
        if buf and buf.index > 0 then
            -- Find oldest sample in window
            local oldest = nil
            local count = math.min(buf.index, MAX_RAW)
            for i = 1, count do
                local s = buf.samples[i]
                if s and s.time >= fromTime and s.time <= ts then
                    if not oldest or s.time < oldest.time then
                        oldest = s
                    end
                end
            end

            if oldest then
                local elapsed = ts - oldest.time
                if elapsed >= 1 then
                    local latestIdx = ((buf.index - 1) % MAX_RAW) + 1
                    local latest = buf.samples[latestIdx]
                    local delta = (latest.value - oldest.value) / elapsed
                    response = {
                        type = "delta_response",
                        key = key,
                        window = windowSeconds,
                        delta = delta,
                        latest = latest.value,
                    }
                end
            end
        end

        if not response then
            response = {
                type = "delta_response",
                key = key,
                window = windowSeconds,
                delta = nil,
                latest = nil,
            }
        end
    end

    if response then
        rednet.send(senderID, textutils.serialize(response), QUERY_CHANNEL)
    end
end

-- ── Setup ──

rednet.open(MODEM_SIDE)

print("Monitor Data Server v" .. VERSION)
print("=== Data Server Starting ===")
print("Loading stored data...")

loadAllFromDisk()
loadMeta()

-- Count loaded resources
local resCount = 0
for _ in pairs(resourceMeta) do resCount = resCount + 1 end
local minCount = 0
for _ in pairs(tierData.minute) do minCount = minCount + 1 end
local hrCount = 0
for _ in pairs(tierData.hourly) do hrCount = hrCount + 1 end
local dayCount = 0
for _ in pairs(tierData.daily) do dayCount = dayCount + 1 end

print("Loaded " .. resCount .. " resources")
print("  Minute series: " .. minCount)
print("  Hourly series: " .. hrCount)
print("  Daily series:  " .. dayCount)
print("")
print("Sensor channel:  " .. SENSOR_CHANNEL)
print("Query channel:   " .. QUERY_CHANNEL)
print("Modem:           " .. MODEM_SIDE)
print("")
print("Hold Ctrl+T to stop (saves data).")
print("")

-- ── Main Loop ──

local lastSave = os.clock()
local lastCleanup = os.clock()
local msgCount = 0
local queryCount = 0

local function updateStatusLine()
    term.setCursorPos(1, 14)
    term.clearLine()
    term.write("Msgs: " .. msgCount .. " | Queries: " .. queryCount)
    term.setCursorPos(1, 15)
    term.clearLine()
    local res = 0
    for _ in pairs(rawBuffers) do res = res + 1 end
    term.write("Active resources: " .. res)
end

-- Save on shutdown
local function shutdown()
    print("")
    print("Saving data to disk...")
    saveAllToDisk()
    saveMeta()
    print("Done. Server stopped.")
end

-- Wrap main loop to ensure save on exit
local ok, err = pcall(function()
    local saveTimer = os.startTimer(DISK_WRITE_INTERVAL)
    local cleanupTimer = os.startTimer(3600) -- cleanup every hour
    local statusTimer = os.startTimer(5)

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "rednet_message" then
            local senderID, msg, proto = p1, p2, p3

            if proto == SENSOR_CHANNEL and msg then
                local ok2, data = pcall(textutils.unserialize, msg)
                if ok2 and type(data) == "table" and data.type then
                    processSensorData(senderID, data)
                    msgCount = msgCount + 1
                end

            elseif proto == QUERY_CHANNEL and msg then
                local ok2, query = pcall(textutils.unserialize, msg)
                if ok2 and type(query) == "table" and query.type then
                    handleQuery(senderID, query)
                    queryCount = queryCount + 1
                end
            end

        elseif event == "timer" then
            if p1 == saveTimer then
                saveAllToDisk()
                saveMeta()
                saveTimer = os.startTimer(DISK_WRITE_INTERVAL)

            elseif p1 == cleanupTimer then
                runCleanup()
                cleanupTimer = os.startTimer(3600)

            elseif p1 == statusTimer then
                updateStatusLine()
                statusTimer = os.startTimer(5)
            end
        end
    end
end)

-- Always save on exit
shutdown()

if not ok then
    print("Error: " .. tostring(err))
end
