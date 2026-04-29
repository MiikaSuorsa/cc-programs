-- Display for CC:Tweaked 1.89.2 (MC 1.12.2)
-- Receives live sensor data, queries data server for history,
-- renders configurable panels with touch navigation.
--
-- Supports single-view and dashboard layouts.

local VERSION = "1.0.0"

-- ══════════════════════════════════════════════════════
-- CONFIG
-- ══════════════════════════════════════════════════════

local MODEM_SIDE = "back"
local MONITOR_SIDE = "top"            -- nil for terminal
local SENSOR_CHANNEL = "monitor"      -- must match sensor.lua
local QUERY_CHANNEL = "monitor_query" -- must match dataserver.lua

-- Redstone alert output (nil to disable)
local ALERT_REDSTONE_SIDE = "right"

-- ── Layout Mode ──
-- "single"    = one view, full touch navigation (mode/resource/time tabs)
-- "dashboard" = multiple fixed panels on one screen
local LAYOUT = "single"

-- ── Dashboard Grid (only used when LAYOUT = "dashboard") ──
local GRID = { cols = 2, rows = 2 }

-- ── Dashboard Panels ──
-- Positioning: grid coords OR manual coords
--   Grid:   { row=1, col=1, rowspan=1, colspan=1, ... }
--   Manual: { x=1, y=1, w=40, h=19, ... }
--
-- Resource:
--   mode: "energy", "items", or "fluids"
--   sensor_id: computer ID of the sensor
--   source: source label from sensor config
--   For items:  resource = "minecraft:diamond", damage = 0
--   For fluids: resource = "industrialforegoing:essence"
--
-- Alerts (optional):
--   alert_low / alert_high = threshold value
--   alert_low_signal / alert_high_signal = redstone strength 1-15
--
-- Labels (optional):
--   label = "My Panel"

local PANELS = {
    {
        row = 1, col = 1,
        mode = "energy", sensor_id = 0, source = "Main Battery",
        alert_low = 100000, alert_low_signal = 8,
    },
    {
        row = 1, col = 2,
        mode = "items", sensor_id = 0, source = "ME System",
        resource = "minecraft:diamond", damage = 0,
        alert_low = 100, alert_low_signal = 15,
    },
    {
        row = 2, col = 1, colspan = 2,
        mode = "fluids", sensor_id = 0, source = "Tank",
        resource = "industrialforegoing:essence",
    },
}

-- ── Alerts for Single Mode ──
local SINGLE_ALERTS = {
    -- {
    --     sensor_id = 0, mode = "energy", source = "Main Battery",
    --     alert_low = 100000, alert_low_signal = 8,
    -- },
}

-- ── Graph Time Views ──
-- label: button text
-- seconds: time window
-- tier: which data tier to query ("raw", "minute", "hourly", "daily")
local GRAPH_VIEWS = {
    { label = " 1m ", seconds = 60,      tier = "raw" },
    { label = " 5m ", seconds = 300,     tier = "raw" },
    { label = "15m ", seconds = 900,     tier = "raw" },
    { label = " 1h ", seconds = 3600,    tier = "minute" },
    { label = " 6h ", seconds = 21600,   tier = "minute" },
    { label = " 1d ", seconds = 86400,   tier = "hourly" },
    { label = " 7d ", seconds = 604800,  tier = "hourly" },
    { label = "30d ", seconds = 2592000, tier = "daily" },
}

-- ── Graph Display Options ──
local GRAPH_OPTIONS = {
    -- Minimum Y range as percentage of max capacity (0 to disable)
    -- Prevents over-zoom on nearly-flat data (e.g. full battery)
    min_range_pct = 5,

    -- Absolute minimum range if no max capacity is known
    min_range_abs = 10000,

    -- Moving average window (1 = raw, 3-5 = smoothed)
    smoothing = 1,

    -- Width reserved for Y-axis labels (in characters)
    y_label_width = 7,

    -- Number of intermediate Y-axis labels (0 to disable)
    y_labels = 2,

    -- Number of X-axis time labels (0 to disable)
    x_labels = 4,
}

-- ── Delta Windows ──
-- Time windows for rate-of-change display (calculated locally)
local DELTA_WINDOWS = {
    { label = "1s",  seconds = 2 },
    { label = "5s",  seconds = 5 },
    { label = "30s", seconds = 30 },
    { label = "1m",  seconds = 60 },
    { label = "5m",  seconds = 300 },
    { label = "1h",  seconds = 3600 },
}

-- ══════════════════════════════════════════════════════
-- END OF CONFIG
-- ══════════════════════════════════════════════════════

-- ── Helpers ──

local function nowSeconds()
    return math.floor(os.epoch("utc") / 1000)
end

local function sanitizeKey(str)
    return str:gsub("[:/\\%.%s]", "_")
end

local function buildResourceKey(mode, sensor_id, source, resource, damage)
    if mode == "energy" then
        return sanitizeKey("energy:" .. sensor_id .. ":" .. source)
    elseif mode == "items" then
        return sanitizeKey("item:" .. sensor_id .. ":" .. resource .. ":" .. (damage or 0))
    elseif mode == "fluids" then
        return sanitizeKey("fluid:" .. sensor_id .. ":" .. resource)
    end
    return "unknown"
end

local function formatNumber(n)
    if n >= 1e9 then
        return string.format("%.2fG", n / 1e9)
    elseif n >= 1e6 then
        return string.format("%.2fM", n / 1e6)
    elseif n >= 1e3 then
        return string.format("%.2fK", n / 1e3)
    else
        return tostring(math.floor(n))
    end
end

local function formatFluid(mB)
    if mB >= 1000 then
        return formatNumber(math.floor(mB / 1000)) .. " B"
    else
        return tostring(math.floor(mB)) .. " mB"
    end
end

local function formatDelta(d, unit)
    local sign = ""
    if d > 0 then sign = "+" end
    return sign .. formatNumber(d) .. " " .. unit .. "/s"
end

local function formatFluidDelta(d)
    if math.abs(d) >= 1000 then
        return formatDelta(math.floor(d / 1000), "B")
    else
        return formatDelta(d, "mB")
    end
end

-- ── Setup ──

rednet.open(MODEM_SIDE)

local display = term
if MONITOR_SIDE then
    local mon = peripheral.wrap(MONITOR_SIDE)
    if mon then
        display = mon
        mon.setTextScale(0.5)
    else
        print("No monitor on " .. MONITOR_SIDE .. ", using terminal.")
    end
end

-- ── Local Delta Tracking ──
-- Each resource gets its own ring buffer so we calculate deltas locally
-- instead of querying the data server every second.

local LOCAL_HISTORY_SIZE = 3600  -- 1 hour of per-second samples
local localHistory = {}          -- key -> { samples = {}, index = 0 }

local function recordLocalSample(key, value)
    if not localHistory[key] then
        localHistory[key] = { samples = {}, index = 0 }
    end
    local buf = localHistory[key]
    buf.index = buf.index + 1
    local idx = ((buf.index - 1) % LOCAL_HISTORY_SIZE) + 1
    buf.samples[idx] = { time = os.clock(), value = value }
end

local function getLocalDelta(key, windowSeconds)
    local buf = localHistory[key]
    if not buf or buf.index == 0 then return nil end

    local clockNow = os.clock()
    local target = clockNow - windowSeconds
    local oldest = nil
    local count = math.min(buf.index, LOCAL_HISTORY_SIZE)

    for i = 1, count do
        local s = buf.samples[i]
        if s and s.time >= target and s.time <= clockNow then
            if not oldest or s.time < oldest.time then
                oldest = s
            end
        end
    end

    if not oldest then return nil end
    local elapsed = clockNow - oldest.time
    if elapsed < 0.5 then return nil end

    local latestIdx = ((buf.index - 1) % LOCAL_HISTORY_SIZE) + 1
    local latest = buf.samples[latestIdx]
    return (latest.value - oldest.value) / elapsed
end

-- ── State ──

local liveData = {}            -- key -> { value, max, meta, lastSeen, ... }
local graphCache = {}          -- cacheKey -> { samples, fetchedAt }
local discoveredResources = {} -- from data server list_resources
local panelStates = {}         -- panel index -> { graphView, ... }
local touchZones = {}          -- { x1, x2, y1, y2, action, ... }
local activeAlerts = {}        -- key -> { signal, alertType }
local flashState = false
local globalTimeOverride = nil
local needsRedraw = true
local needsFullClear = true  -- only true on startup and structural changes
local running = true

-- Graph inspect state (touch-to-read values)
local inspectState = {}  -- panelIdx -> { col, value, time, screenX, screenY }
local graphColumnData = {} -- panelIdx -> { columns, fromTime, sliceWidth, visMin, visMax, plotX, plotY, plotW, plotH }

-- Single mode navigation state
local singleMode = "energy"
local singleResourceIdx = 1
local singleResources = {}
local resourceScrollOffset = 0  -- how many resource tabs to skip from the left

-- ── Panel State Init ──

local function initPanelStates()
    panelStates = {}
    local count = LAYOUT == "dashboard" and #PANELS or 1
    for i = 1, count do
        panelStates[i] = { graphView = 1 }
    end
end

initPanelStates()

-- ── Data Server Communication ──

local DATA_SERVER_ID = nil

local function sendQuery(query)
    if DATA_SERVER_ID then
        rednet.send(DATA_SERVER_ID, textutils.serialize(query), QUERY_CHANNEL)
    else
        rednet.broadcast(textutils.serialize(query), QUERY_CHANNEL)
    end
end

local function requestGraphData(key, viewIdx)
    local view = GRAPH_VIEWS[viewIdx]
    if not view then return end
    local toTime = nowSeconds()
    local fromTime = toTime - view.seconds
    sendQuery({
        type = "query",
        key = key,
        tier = view.tier,
        from = fromTime,
        to = toTime,
    })
end

local function requestResourceList()
    sendQuery({ type = "list_resources" })
end

-- ── Live Data Processing ──

local function processLiveSensorData(data)
    local ts = nowSeconds()

    if data.type == "energy" then
        local key = sanitizeKey("energy:" .. data.sensorID .. ":" .. data.source)
        liveData[key] = {
            type = "energy",
            value = data.storedRF,
            raw = data.stored,
            max = data.maxRF,
            rawMax = data.max,
            unit = data.unit,
            conversion = data.conversion,
            usage = data.usage,
            usageRF = data.usageRF,
            source = data.source,
            sensorID = data.sensorID,
            sensorLabel = data.label,
            lastSeen = ts,
        }
        recordLocalSample(key, data.storedRF)

    elseif data.type == "items" then
        for _, item in ipairs(data.items) do
            local key = sanitizeKey("item:" .. data.sensorID .. ":" .. item.name .. ":" .. item.damage)
            liveData[key] = {
                type = "item",
                value = item.count,
                label = item.label,
                itemName = item.name,
                itemDamage = item.damage,
                isCraftable = item.isCraftable,
                source = data.source,
                sensorID = data.sensorID,
                sensorLabel = data.label,
                lastSeen = ts,
            }
            recordLocalSample(key, item.count)
        end

    elseif data.type == "fluids" then
        for _, fluid in ipairs(data.fluids) do
            local key = sanitizeKey("fluid:" .. data.sensorID .. ":" .. fluid.id)
            liveData[key] = {
                type = "fluid",
                value = fluid.amount,
                max = fluid.capacity,
                label = fluid.label,
                fluidID = fluid.id,
                source = data.source,
                sensorID = data.sensorID,
                sensorLabel = data.label,
                lastSeen = ts,
            }
            recordLocalSample(key, fluid.amount)
        end
    end
end

-- ── Process Query Responses ──

local function processQueryResponse(senderID, response)
    DATA_SERVER_ID = senderID

    if response.type == "resource_list" then
        discoveredResources = response.resources or {}
        needsRedraw = true

    elseif response.type == "query_response" then
        local cacheKey = response.key .. ":" .. (response.tier or "")
        graphCache[cacheKey] = {
            samples = response.samples or {},
            fetchedAt = os.clock(),
        }
        -- Don't set needsRedraw here; the regular timer will pick it up.
        -- Immediate redraws on every response cause visible flicker.
    end
end

-- ── Alert Processing ──

local function checkAlerts()
    activeAlerts = {}
    local maxSignal = 0

    local alertConfigs = {}

    if LAYOUT == "dashboard" then
        for i, panel in ipairs(PANELS) do
            if panel.alert_low or panel.alert_high then
                local key = buildResourceKey(
                    panel.mode, panel.sensor_id, panel.source,
                    panel.resource, panel.damage
                )
                table.insert(alertConfigs, {
                    key = key,
                    alert_low = panel.alert_low,
                    alert_low_signal = panel.alert_low_signal or 8,
                    alert_high = panel.alert_high,
                    alert_high_signal = panel.alert_high_signal or 8,
                })
            end
        end
    else
        for _, alert in ipairs(SINGLE_ALERTS) do
            local key = buildResourceKey(
                alert.mode, alert.sensor_id, alert.source,
                alert.resource, alert.damage
            )
            table.insert(alertConfigs, {
                key = key,
                alert_low = alert.alert_low,
                alert_low_signal = alert.alert_low_signal or 8,
                alert_high = alert.alert_high,
                alert_high_signal = alert.alert_high_signal or 8,
            })
        end
    end

    for _, ac in ipairs(alertConfigs) do
        local live = liveData[ac.key]
        if live then
            local val = live.value
            local sig = 0
            local aType = nil

            if ac.alert_low and val <= ac.alert_low then
                sig = ac.alert_low_signal
                aType = "low"
            end
            if ac.alert_high and val >= ac.alert_high then
                if ac.alert_high_signal > sig then
                    sig = ac.alert_high_signal
                end
                aType = "high"
            end

            if aType then
                activeAlerts[ac.key] = { signal = sig, alertType = aType }
                if sig > maxSignal then maxSignal = sig end
            end
        end
    end

    if ALERT_REDSTONE_SIDE then
        rs.setAnalogOutput(ALERT_REDSTONE_SIDE, maxSignal)
    end
end

-- ── Resource Discovery for Single Mode ──

local function updateSingleResources()
    singleResources = {}
    local targetType
    if singleMode == "energy" then targetType = "energy"
    elseif singleMode == "items" then targetType = "item"
    elseif singleMode == "fluids" then targetType = "fluid"
    end

    -- From live data
    for key, live in pairs(liveData) do
        if live.type == targetType then
            local label
            if targetType == "energy" then
                label = live.source or live.sensorLabel
            elseif targetType == "item" then
                label = live.label or live.itemName
            elseif targetType == "fluid" then
                label = live.label or live.fluidID
            end
            table.insert(singleResources, { key = key, label = label or key })
        end
    end

    -- Also from discovered resources (data server knows about)
    for key, meta in pairs(discoveredResources) do
        if meta.type == targetType then
            local found = false
            for _, r in ipairs(singleResources) do
                if r.key == key then found = true; break end
            end
            if not found then
                local label
                if targetType == "energy" then label = meta.source
                elseif targetType == "item" then label = meta.itemLabel or meta.itemName
                elseif targetType == "fluid" then label = meta.fluidLabel or meta.fluidID
                end
                table.insert(singleResources, { key = key, label = label or key })
            end
        end
    end

    if singleResourceIdx > #singleResources then
        singleResourceIdx = math.max(1, #singleResources)
    end
end

local function getSingleKey()
    if singleResources and singleResources[singleResourceIdx] then
        return singleResources[singleResourceIdx].key
    end
    return nil
end

-- ── Drawing Helpers ──

local function addTouchZone(x1, y1, x2, y2, action, data)
    table.insert(touchZones, {
        x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        action = action, data = data,
    })
end

-- Write text and pad remainder with spaces to overwrite old content
local function padWrite(d, x, y, text, width)
    d.setCursorPos(x, y)
    d.write(text)
    local pad = width - #text
    if pad > 0 then
        d.setBackgroundColor(colors.black)
        d.write(string.rep(" ", pad))
    end
end

local function drawBar(d, x, y, width, pct, fgColor)
    local filled = math.floor((pct / 100) * width)
    if filled > width then filled = width end
    if filled < 0 then filled = 0 end
    d.setCursorPos(x, y)
    d.setBackgroundColor(fgColor or colors.green)
    d.write(string.rep(" ", filled))
    d.setBackgroundColor(colors.gray)
    d.write(string.rep(" ", width - filled))
    d.setBackgroundColor(colors.black)
end

local function drawBorder(d, x, y, w, h, color)
    d.setTextColor(color)
    d.setBackgroundColor(colors.black)
    d.setCursorPos(x, y)
    d.write("+" .. string.rep("-", w - 2) .. "+")
    d.setCursorPos(x, y + h - 1)
    d.write("+" .. string.rep("-", w - 2) .. "+")
    for row = y + 1, y + h - 2 do
        d.setCursorPos(x, row)
        d.write("|")
        d.setCursorPos(x + w - 1, row)
        d.write("|")
    end
end

local function clearArea(d, x, y, w, h)
    d.setBackgroundColor(colors.black)
    for row = y, y + h - 1 do
        d.setCursorPos(x, row)
        d.write(string.rep(" ", w))
    end
end

-- ── Graph Drawing ──

-- Format seconds ago into a relative time label
local function formatTimeAgo(secsAgo)
    if secsAgo < 60 then
        return "-" .. math.floor(secsAgo) .. "s"
    elseif secsAgo < 3600 then
        return "-" .. math.floor(secsAgo / 60) .. "m"
    elseif secsAgo < 86400 then
        local h = math.floor(secsAgo / 3600)
        local m = math.floor((secsAgo % 3600) / 60)
        if m > 0 then
            return "-" .. h .. "h" .. m .. "m"
        end
        return "-" .. h .. "h"
    else
        local d = math.floor(secsAgo / 86400)
        return "-" .. d .. "d"
    end
end

-- Apply moving average smoothing to column data
local function smoothColumns(columns, window)
    if window <= 1 then return columns end
    local half = math.floor(window / 2)
    local smoothed = {}
    for i = 1, #columns do
        if columns[i].hasData then
            local sum = 0
            local count = 0
            for j = math.max(1, i - half), math.min(#columns, i + half) do
                if columns[j] and columns[j].hasData then
                    sum = sum + columns[j].value
                    count = count + 1
                end
            end
            smoothed[i] = { value = sum / count, hasData = true }
        else
            smoothed[i] = { hasData = false }
        end
    end
    return smoothed
end

local function drawGraph(d, gx, gy, gw, gh, key, panelIdx)
    local state = panelStates[panelIdx]
    if not state then return end

    local viewIdx = globalTimeOverride or state.graphView
    local view = GRAPH_VIEWS[viewIdx]
    if not view then return end

    local yLabelW = GRAPH_OPTIONS.y_label_width or 7

    -- Draw time tabs (only show what fits)
    local tabX = gx
    for i, v in ipairs(GRAPH_VIEWS) do
        if tabX + #v.label > gx + gw then break end
        if i == viewIdx then
            d.setBackgroundColor(colors.cyan)
            d.setTextColor(colors.black)
        else
            d.setBackgroundColor(colors.gray)
            d.setTextColor(colors.white)
        end
        d.setCursorPos(tabX, gy)
        d.write(v.label)
        addTouchZone(tabX, gy, tabX + #v.label - 1, gy, "graph_time", { panel = panelIdx, view = i })
        tabX = tabX + #v.label + 1
    end
    d.setBackgroundColor(colors.black)

    -- Plot area: leave room for Y labels on left and X labels on bottom
    local plotX = gx + yLabelW
    local plotY = gy + 1
    local plotW = gw - yLabelW
    local plotH = gh - 3  -- room for tabs on top, axis + labels on bottom
    if plotH < 3 or plotW < 5 then return end

    -- Clear the plot area + label areas
    d.setBackgroundColor(colors.black)
    for row = plotY, plotY + plotH + 1 do
        d.setCursorPos(gx, row)
        d.write(string.rep(" ", gw))
    end

    -- Get cached graph data
    local cacheKey = key .. ":" .. view.tier
    local cached = graphCache[cacheKey]

    if not cached or (os.clock() - cached.fetchedAt) > 15 then
        requestGraphData(key, viewIdx)
    end

    if not cached or #cached.samples < 2 then
        d.setCursorPos(plotX + 1, plotY + math.floor(plotH / 2))
        d.setTextColor(colors.lightGray)
        d.write("waiting...")
        return
    end

    local samples = cached.samples
    local toTime = nowSeconds()
    local fromTime = toTime - view.seconds
    local sliceWidth = view.seconds / plotW

    -- Bucket samples into columns
    local columns = {}
    for col = 1, plotW do
        local sliceStart = fromTime + (col - 1) * sliceWidth
        local sliceEnd = fromTime + col * sliceWidth
        local sum, count = 0, 0
        for _, s in ipairs(samples) do
            if s.time >= sliceStart and s.time < sliceEnd then
                sum = sum + s.value
                count = count + 1
            end
        end
        if count > 0 then
            columns[col] = { value = sum / count, hasData = true, time = sliceStart + sliceWidth / 2 }
        else
            columns[col] = { hasData = false }
        end
    end

    -- Apply smoothing
    columns = smoothColumns(columns, GRAPH_OPTIONS.smoothing or 1)

    -- Find min/max
    local visMin, visMax = math.huge, -math.huge
    local hasAny = false
    for _, col in pairs(columns) do
        if col.hasData then
            hasAny = true
            if col.value < visMin then visMin = col.value end
            if col.value > visMax then visMax = col.value end
        end
    end

    if not hasAny then
        d.setCursorPos(plotX + 1, plotY + math.floor(plotH / 2))
        d.setTextColor(colors.lightGray)
        d.write("no data")
        return
    end

    -- Noise reduction: enforce minimum range
    local range = visMax - visMin
    local live = liveData[key]
    local minRange = GRAPH_OPTIONS.min_range_abs or 10000

    if live and live.max and GRAPH_OPTIONS.min_range_pct > 0 then
        local pctRange = live.max * (GRAPH_OPTIONS.min_range_pct / 100)
        if pctRange > minRange then minRange = pctRange end
    end

    if range < minRange then
        local center = (visMin + visMax) / 2
        visMin = center - minRange / 2
        visMax = center + minRange / 2
        if visMin < 0 then
            visMin = 0
            visMax = minRange
        end
    else
        -- Normal padding
        visMin = visMin - range * 0.05
        visMax = visMax + range * 0.05
    end
    range = visMax - visMin
    if range == 0 then range = 1 end

    -- Store column data for touch-inspect
    graphColumnData[panelIdx] = {
        columns = columns,
        fromTime = fromTime,
        sliceWidth = sliceWidth,
        visMin = visMin,
        visMax = visMax,
        plotX = plotX,
        plotY = plotY,
        plotW = plotW,
        plotH = plotH,
    }

    -- ── Y-axis labels ──
    d.setBackgroundColor(colors.black)
    d.setTextColor(colors.lightGray)

    -- Top label (max)
    d.setCursorPos(gx, plotY)
    d.write(formatNumber(visMax))

    -- Bottom label (min)
    d.setCursorPos(gx, plotY + plotH - 1)
    d.write(formatNumber(visMin))

    -- Intermediate Y labels
    local numYLabels = GRAPH_OPTIONS.y_labels or 2
    for i = 1, numYLabels do
        local frac = i / (numYLabels + 1)
        local labelVal = visMin + range * frac
        local labelY = plotY + plotH - 1 - math.floor(frac * (plotH - 1))
        d.setTextColor(colors.lightGray)
        d.setCursorPos(gx, labelY)
        d.write(formatNumber(labelVal))
        -- Draw a subtle tick mark at the plot edge
        d.setCursorPos(plotX, labelY)
        d.write("-")
    end

    -- ── X-axis ──
    d.setTextColor(colors.lightGray)
    local axisY = plotY + plotH
    d.setCursorPos(plotX, axisY)
    d.write(string.rep("-", plotW))

    -- X-axis time labels
    local numXLabels = GRAPH_OPTIONS.x_labels or 4
    if numXLabels > 0 then
        local labelY2 = axisY + 1
        for i = 0, numXLabels do
            local frac = i / numXLabels
            local labelX = plotX + math.floor(frac * (plotW - 1))
            local secsAgo = view.seconds * (1 - frac)

            -- Tick mark on axis
            d.setCursorPos(labelX, axisY)
            d.write("|")

            -- Time label below axis
            local timeLabel
            if secsAgo < 1 then
                timeLabel = "now"
            else
                timeLabel = formatTimeAgo(secsAgo)
            end

            -- Center the label on the tick position
            local labelStart = labelX - math.floor(#timeLabel / 2)
            if labelStart < gx then labelStart = gx end
            if labelStart + #timeLabel > gx + gw then
                labelStart = gx + gw - #timeLabel
            end
            d.setCursorPos(labelStart, labelY2)
            d.write(timeLabel)
        end
    end

    -- ── Plot data points ──
    local points = {}
    for i = 1, plotW do
        if columns[i] and columns[i].hasData then
            local normY = (columns[i].value - visMin) / range
            local screenY = plotY + plotH - 1 - math.floor(normY * (plotH - 1))
            table.insert(points, { x = plotX + i - 1, y = screenY, idx = i })
        end
    end

    local prev = term.redirect(d)
    for i = 2, #points do
        local col = colors.green
        if columns[points[i].idx].value < columns[points[i-1].idx].value then
            col = colors.red
        end
        paintutils.drawLine(points[i-1].x, points[i-1].y, points[i].x, points[i].y, col)
    end
    if #points == 1 then
        paintutils.drawPixel(points[1].x, points[1].y, colors.green)
    end
    term.redirect(prev)

    -- ── Touch inspect marker ──
    local inspect = inspectState[panelIdx]
    if inspect and inspect.col >= 1 and inspect.col <= plotW then
        local normY = (inspect.value - visMin) / range
        local markerY = plotY + plotH - 1 - math.floor(normY * (plotH - 1))
        local markerX = plotX + inspect.col - 1

        -- Vertical line
        d.setTextColor(colors.yellow)
        d.setBackgroundColor(colors.black)
        for row = plotY, plotY + plotH - 1 do
            if row ~= markerY then
                d.setCursorPos(markerX, row)
                d.write(":")
            end
        end

        -- Highlight point
        d.setBackgroundColor(colors.yellow)
        d.setTextColor(colors.black)
        d.setCursorPos(markerX, markerY)
        d.write("O")

        -- Value tooltip
        local valText = formatNumber(inspect.value)
        local timeText = ""
        if inspect.secsAgo then
            timeText = " " .. formatTimeAgo(inspect.secsAgo)
        end
        local tooltip = valText .. timeText

        -- Position tooltip above or below the marker
        local tooltipY = markerY - 1
        if tooltipY < plotY then tooltipY = markerY + 1 end
        local tooltipX = markerX - math.floor(#tooltip / 2)
        if tooltipX < plotX then tooltipX = plotX end
        if tooltipX + #tooltip > plotX + plotW then
            tooltipX = plotX + plotW - #tooltip
        end

        d.setBackgroundColor(colors.yellow)
        d.setTextColor(colors.black)
        d.setCursorPos(tooltipX, tooltipY)
        d.write(tooltip)
        d.setBackgroundColor(colors.black)
    end

    -- Add touch zone for the graph plot area
    addTouchZone(plotX, plotY, plotX + plotW - 1, plotY + plotH - 1, "graph_inspect", { panel = panelIdx })
end

-- ── Deltas Drawing ──

local function drawDeltas(d, x, startRow, maxRow, key, unit)
    d.setCursorPos(x, startRow)
    d.setTextColor(colors.cyan)
    d.write("== Flow ==")

    local row = startRow + 1
    for _, win in ipairs(DELTA_WINDOWS) do
        if row >= maxRow then break end
        d.setCursorPos(x, row)
        d.setTextColor(colors.white)
        d.write(string.format("%-4s ", win.label))

        local delta = getLocalDelta(key, win.seconds)
        if delta then
            if delta > 0 then d.setTextColor(colors.green)
            elseif delta < 0 then d.setTextColor(colors.red)
            else d.setTextColor(colors.lightGray) end
            if unit == "fluid" then
                d.write(formatFluidDelta(delta))
            else
                d.write(formatDelta(delta, unit))
            end
        else
            d.setTextColor(colors.lightGray)
            d.write("...")
        end
        row = row + 1
    end
    return row
end

-- ── Panel Renderers ──

local function drawEnergyPanel(d, x, y, w, h, key, panelIdx)
    local live = liveData[key]
    local pw = math.min(24, math.floor(w * 0.4))

    -- Clear the text panel area
    d.setBackgroundColor(colors.black)
    for row = y, y + h - 1 do
        d.setCursorPos(x, row)
        d.write(string.rep(" ", pw))
    end

    d.setCursorPos(x, y)
    d.setTextColor(colors.lightGray)
    local srcText = live and (live.source or live.sensorLabel) or "?"
    d.write(string.sub(srcText, 1, pw - 7))

    local online = live and (nowSeconds() - live.lastSeen) < 15
    d.setCursorPos(x + pw - 6, y)
    if online then
        d.setTextColor(colors.green)
        d.write("ONLINE")
    else
        d.setTextColor(colors.red)
        d.write("NO SIG")
    end

    if not live then return end

    local row = y + 1
    if live.max then
        local pct = (live.value / live.max) * 100
        d.setCursorPos(x, row)
        d.setTextColor(colors.white)
        d.write("Charge: ")
        if pct > 60 then d.setTextColor(colors.green)
        elseif pct > 25 then d.setTextColor(colors.yellow)
        else d.setTextColor(colors.red) end
        d.write(string.format("%.1f%%", pct))
        row = row + 1
        drawBar(d, x, row, pw, pct)
        row = row + 1
    end

    row = row + 1
    d.setCursorPos(x, row)
    d.setTextColor(colors.white)
    d.write("Now: ")
    d.setTextColor(colors.lime)
    d.write(formatNumber(live.value) .. " RF")
    row = row + 1

    if live.unit and live.unit ~= "RF" then
        d.setCursorPos(x, row)
        d.setTextColor(colors.lightGray)
        d.write("    (" .. formatNumber(live.raw) .. " " .. live.unit .. ")")
        row = row + 1
    end

    if live.max then
        d.setCursorPos(x, row)
        d.setTextColor(colors.white)
        d.write("Max: ")
        d.setTextColor(colors.lightBlue)
        d.write(formatNumber(live.max) .. " RF")
        row = row + 1
    end

    if live.usage then
        d.setCursorPos(x, row)
        d.setTextColor(colors.white)
        d.write("Draw: ")
        d.setTextColor(colors.orange)
        d.write(string.format("%.1f", live.usageRF) .. " RF/t")
        row = row + 1
    end

    row = row + 1
    drawDeltas(d, x, row, y + h, key, "RF")

    local graphX = x + pw + 1
    local graphW = w - pw - 2
    if graphW > 8 then
        drawGraph(d, graphX, y, graphW, h, key, panelIdx)
    end
end

local function drawItemPanel(d, x, y, w, h, key, panelIdx)
    local live = liveData[key]
    local pw = math.min(24, math.floor(w * 0.4))

    -- Clear the text panel area
    d.setBackgroundColor(colors.black)
    for row = y, y + h - 1 do
        d.setCursorPos(x, row)
        d.write(string.rep(" ", pw))
    end

    d.setCursorPos(x, y)
    d.setTextColor(colors.white)
    local itemLabel = live and (live.label or live.itemName) or "?"
    d.write(string.sub(itemLabel, 1, pw - 7))

    local online = live and (nowSeconds() - live.lastSeen) < 15
    d.setCursorPos(x + pw - 6, y)
    if online then
        d.setTextColor(colors.green)
        d.write("ONLINE")
    else
        d.setTextColor(colors.red)
        d.write("NO SIG")
    end

    d.setCursorPos(x, y + 1)
    d.setTextColor(colors.lightGray)
    local srcText = live and (live.source or live.sensorLabel) or "?"
    d.write(string.sub("Src: " .. srcText, 1, pw))

    if not live then return end

    local row = y + 3
    d.setCursorPos(x, row)
    d.setTextColor(colors.white)
    d.write("Count: ")
    d.setTextColor(colors.lime)
    d.write(formatNumber(live.value))
    row = row + 1

    if live.isCraftable then
        d.setCursorPos(x, row)
        d.setTextColor(colors.purple)
        d.write("[Craftable]")
        row = row + 1
    end

    row = row + 1
    drawDeltas(d, x, row, y + h, key, "items")

    local graphX = x + pw + 1
    local graphW = w - pw - 2
    if graphW > 8 then
        drawGraph(d, graphX, y, graphW, h, key, panelIdx)
    end
end

local function drawFluidPanel(d, x, y, w, h, key, panelIdx)
    local live = liveData[key]
    local pw = math.min(24, math.floor(w * 0.4))

    -- Clear the text panel area
    d.setBackgroundColor(colors.black)
    for row = y, y + h - 1 do
        d.setCursorPos(x, row)
        d.write(string.rep(" ", pw))
    end

    d.setCursorPos(x, y)
    d.setTextColor(colors.white)
    local fLabel = live and (live.label or live.fluidID) or "?"
    d.write(string.sub(fLabel, 1, pw - 7))

    local online = live and (nowSeconds() - live.lastSeen) < 15
    d.setCursorPos(x + pw - 6, y)
    if online then
        d.setTextColor(colors.green)
        d.write("ONLINE")
    else
        d.setTextColor(colors.red)
        d.write("NO SIG")
    end

    d.setCursorPos(x, y + 1)
    d.setTextColor(colors.lightGray)
    local srcText = live and (live.source or live.sensorLabel) or "?"
    d.write(string.sub("Src: " .. srcText, 1, pw))

    if not live then return end

    local row = y + 3
    if live.max then
        local pct = (live.value / live.max) * 100
        d.setCursorPos(x, row)
        d.setTextColor(colors.white)
        d.write("Fill: ")
        if pct > 60 then d.setTextColor(colors.blue)
        elseif pct > 25 then d.setTextColor(colors.yellow)
        else d.setTextColor(colors.red) end
        d.write(string.format("%.1f%%", pct))
        row = row + 1
        drawBar(d, x, row, pw, pct, colors.blue)
        row = row + 1
    end

    row = row + 1
    d.setCursorPos(x, row)
    d.setTextColor(colors.white)
    d.write("Amt: ")
    d.setTextColor(colors.blue)
    d.write(formatFluid(live.value))
    row = row + 1

    if live.max then
        d.setCursorPos(x, row)
        d.setTextColor(colors.white)
        d.write("Cap: ")
        d.setTextColor(colors.lightBlue)
        d.write(formatFluid(live.max))
        row = row + 1
    end

    row = row + 1
    drawDeltas(d, x, row, y + h, key, "fluid")

    local graphX = x + pw + 1
    local graphW = w - pw - 2
    if graphW > 8 then
        drawGraph(d, graphX, y, graphW, h, key, panelIdx)
    end
end

-- ── Draw a Single Panel ──

local function drawPanel(d, x, y, w, h, panelIdx, panelCfg, key)
    local isAlerting = activeAlerts[key] ~= nil

    if LAYOUT == "dashboard" then
        if isAlerting and flashState then
            drawBorder(d, x, y, w, h, colors.red)
        else
            drawBorder(d, x, y, w, h, colors.lightGray)
        end
        -- Inset for border
        x = x + 1
        y = y + 1
        w = w - 2
        h = h - 2
    else
        -- Single mode: always reserve border space, change color on alert
        if isAlerting and flashState then
            drawBorder(d, x, y, w, h, colors.red)
        else
            drawBorder(d, x, y, w, h, colors.lightGray)
        end
        x = x + 1
        y = y + 1
        w = w - 2
        h = h - 2
    end

    if w < 10 or h < 5 then return end

    local mode = panelCfg and panelCfg.mode or singleMode

    if mode == "energy" then
        drawEnergyPanel(d, x, y, w, h, key, panelIdx)
    elseif mode == "items" then
        drawItemPanel(d, x, y, w, h, key, panelIdx)
    elseif mode == "fluids" then
        drawFluidPanel(d, x, y, w, h, key, panelIdx)
    end
end

-- ── Dashboard Panel Geometry ──

local function resolvePanelGeometry(panel, screenW, screenH)
    if panel.x then
        return panel.x, panel.y, panel.w, panel.h
    else
        local cellW = math.floor(screenW / GRID.cols)
        local cellH = math.floor(screenH / GRID.rows)
        local colspan = panel.colspan or 1
        local rowspan = panel.rowspan or 1
        local px = (panel.col - 1) * cellW + 1
        local py = (panel.row - 1) * cellH + 1
        local pw = cellW * colspan
        local ph = cellH * rowspan
        return px, py, pw, ph
    end
end

-- ── Single Mode Tabs ──

local function drawSingleTabs(d, w)
    -- Check which mode types have alerts
    local modeHasAlert = { energy = false, items = false, fluids = false }
    for key, _ in pairs(activeAlerts) do
        if key:find("^energy_") then modeHasAlert.energy = true
        elseif key:find("^item_") then modeHasAlert.items = true
        elseif key:find("^fluid_") then modeHasAlert.fluids = true
        end
    end

    local modes = {
        { label = " Energy ", mode = "energy" },
        { label = " Items  ", mode = "items" },
        { label = " Fluids ", mode = "fluids" },
    }
    local tabX = 1
    for _, m in ipairs(modes) do
        if modeHasAlert[m.mode] and flashState then
            d.setBackgroundColor(colors.red)
            d.setTextColor(colors.white)
        elseif m.mode == singleMode then
            d.setBackgroundColor(colors.cyan)
            d.setTextColor(colors.black)
        else
            d.setBackgroundColor(colors.gray)
            d.setTextColor(colors.white)
        end
        d.setCursorPos(tabX, 1)
        d.write(m.label)
        addTouchZone(tabX, 1, tabX + #m.label - 1, 1, "mode_tab", { mode = m.mode })
        tabX = tabX + #m.label + 1
    end
    d.setBackgroundColor(colors.black)

    -- ── Resource tabs with scroll arrows ──

    updateSingleResources()

    if #singleResources == 0 then
        d.setCursorPos(1, 2)
        d.setTextColor(colors.lightGray)
        d.write("Waiting for sensor data...")
        return
    end

    -- Clamp scroll offset
    if resourceScrollOffset >= #singleResources then
        resourceScrollOffset = math.max(0, #singleResources - 1)
    end
    if resourceScrollOffset < 0 then
        resourceScrollOffset = 0
    end

    -- Auto-scroll to keep selected resource visible
    -- We'll calculate visible range after first pass, but ensure selected is reachable
    if singleResourceIdx <= resourceScrollOffset then
        resourceScrollOffset = singleResourceIdx - 1
    end

    local hasLeftArrow = resourceScrollOffset > 0
    local resX = 1

    -- Left arrow
    if hasLeftArrow then
        d.setBackgroundColor(colors.white)
        d.setTextColor(colors.black)
        d.setCursorPos(resX, 2)
        d.write("<")
        addTouchZone(resX, 2, resX, 2, "res_scroll_left", {})
        resX = resX + 2
    end

    -- Draw visible resource tabs
    local rightArrowSpace = 2  -- reserve space for possible > arrow
    local lastVisibleIdx = 0
    for i = resourceScrollOffset + 1, #singleResources do
        local res = singleResources[i]
        local lbl = " " .. string.sub(res.label, 1, 10) .. " "

        -- Check if this tab fits (reserve space for right arrow if more tabs exist)
        local spaceNeeded = #lbl
        local remaining = w - resX + 1
        local moreAfter = (i < #singleResources)
        if moreAfter then
            remaining = remaining - rightArrowSpace
        end
        if spaceNeeded > remaining then
            break
        end

        local resAlerting = activeAlerts[res.key] ~= nil

        if resAlerting and flashState then
            d.setBackgroundColor(colors.red)
            d.setTextColor(colors.white)
        elseif i == singleResourceIdx then
            d.setBackgroundColor(colors.lime)
            d.setTextColor(colors.black)
        else
            d.setBackgroundColor(colors.gray)
            d.setTextColor(colors.white)
        end
        d.setCursorPos(resX, 2)
        d.write(lbl)
        addTouchZone(resX, 2, resX + #lbl - 1, 2, "resource_tab", { index = i })
        resX = resX + #lbl + 1
        lastVisibleIdx = i
    end

    -- Right arrow if more tabs exist beyond what's visible
    if lastVisibleIdx < #singleResources then
        d.setBackgroundColor(colors.white)
        d.setTextColor(colors.black)
        d.setCursorPos(w, 2)
        d.write(">")
        addTouchZone(w, 2, w, 2, "res_scroll_right", {})
    end

    -- Auto-scroll right if selected resource is past visible range
    if singleResourceIdx > lastVisibleIdx and lastVisibleIdx > 0 then
        resourceScrollOffset = resourceScrollOffset + 1
        needsRedraw = true
    end

    d.setBackgroundColor(colors.black)
end

-- ── Global Time Override Button ──

local function drawGlobalTimeBtn(d, w, h)
    local label
    if globalTimeOverride then
        label = "[ALL:" .. GRAPH_VIEWS[globalTimeOverride].label .. "]"
    else
        label = "[ALL]"
    end
    local bx = w - #label + 1
    if bx < 1 then bx = 1 end
    if globalTimeOverride then
        d.setBackgroundColor(colors.orange)
        d.setTextColor(colors.black)
    else
        d.setBackgroundColor(colors.gray)
        d.setTextColor(colors.white)
    end
    d.setCursorPos(bx, h)
    d.write(label)
    addTouchZone(bx, h, bx + #label - 1, h, "global_time", {})
    d.setBackgroundColor(colors.black)
end

-- ── Main Draw ──

local function drawScreen()
    touchZones = {}
    local w, h = display.getSize()

    -- Only full clear on structural changes (tab switches, startup)
    if needsFullClear then
        display.setBackgroundColor(colors.black)
        display.setTextColor(colors.white)
        display.clear()
        needsFullClear = false
    end

    if LAYOUT == "single" then
        drawSingleTabs(display, w)

        local key = getSingleKey()
        if key then
            drawPanel(display, 1, 3, w, h - 3, 1, nil, key)
        end

    elseif LAYOUT == "dashboard" then
        for i, panel in ipairs(PANELS) do
            local px, py, pw, ph = resolvePanelGeometry(panel, w, h)
            local key = buildResourceKey(
                panel.mode, panel.sensor_id, panel.source,
                panel.resource, panel.damage
            )
            drawPanel(display, px, py, pw, ph, i, panel, key)
        end

        drawGlobalTimeBtn(display, w, h)
    end
end

-- ── Touch Handling ──

local function handleTouch(tx, ty)
    for _, zone in ipairs(touchZones) do
        if tx >= zone.x1 and tx <= zone.x2 and ty >= zone.y1 and ty <= zone.y2 then
            if zone.action == "mode_tab" then
                singleMode = zone.data.mode
                singleResourceIdx = 1
                resourceScrollOffset = 0
                needsFullClear = true
                return true
            elseif zone.action == "resource_tab" then
                singleResourceIdx = zone.data.index
                needsFullClear = true
                return true
            elseif zone.action == "res_scroll_left" then
                resourceScrollOffset = math.max(0, resourceScrollOffset - 3)
                needsFullClear = true
                return true
            elseif zone.action == "res_scroll_right" then
                resourceScrollOffset = resourceScrollOffset + 3
                needsFullClear = true
                return true
            elseif zone.action == "graph_inspect" then
                local pi = zone.data.panel
                local gcd = graphColumnData[pi]
                if gcd then
                    -- Map touch X to column index
                    local col = tx - gcd.plotX + 1
                    if col >= 1 and col <= gcd.plotW and gcd.columns[col] and gcd.columns[col].hasData then
                        local secsAgo = (gcd.fromTime + gcd.plotW * gcd.sliceWidth) - (gcd.fromTime + (col - 0.5) * gcd.sliceWidth)
                        inspectState[pi] = {
                            col = col,
                            value = gcd.columns[col].value,
                            secsAgo = secsAgo,
                        }
                    else
                        -- Touched empty area, clear inspect
                        inspectState[pi] = nil
                    end
                end
                return true
            elseif zone.action == "graph_time" then
                local pi = zone.data.panel
                inspectState[pi] = nil  -- clear inspect on time change
                if panelStates[pi] then
                    panelStates[pi].graphView = zone.data.view
                    globalTimeOverride = nil
                end
                needsFullClear = true
                return true
            elseif zone.action == "global_time" then
                inspectState = {}  -- clear all inspects
                if globalTimeOverride then
                    if globalTimeOverride >= #GRAPH_VIEWS then
                        globalTimeOverride = nil
                    else
                        globalTimeOverride = globalTimeOverride + 1
                    end
                else
                    globalTimeOverride = 1
                end
                needsFullClear = true
                return true
            end
        end
    end
    return false
end

-- ── Startup ──

print("Monitor Display v" .. VERSION)
print("=== Display Starting ===")
print("Layout: " .. LAYOUT)
print("Requesting resource list...")
requestResourceList()

-- ── Main Event Loop ──

local redrawTimer = os.startTimer(2)
local flashTimer = os.startTimer(0.5)
local discoveryTimer = os.startTimer(10)

while running do
    local event, p1, p2, p3 = os.pullEventRaw()

    -- Handle terminate (Ctrl+T)
    if event == "terminate" then
        running = false
        if ALERT_REDSTONE_SIDE then
            rs.setAnalogOutput(ALERT_REDSTONE_SIDE, 0)
        end
        display.setBackgroundColor(colors.black)
        display.clear()
        display.setCursorPos(1, 1)
        display.setTextColor(colors.white)
        display.write("Display stopped.")
        print("Display stopped.")
        break
    end

    if event == "rednet_message" then
        local senderID, msg, proto = p1, p2, p3

        if proto == SENSOR_CHANNEL and msg then
            local ok, data = pcall(textutils.unserialize, msg)
            if ok and type(data) == "table" and data.type then
                processLiveSensorData(data)
                needsRedraw = true
            end

        elseif proto == QUERY_CHANNEL and msg then
            local ok, response = pcall(textutils.unserialize, msg)
            if ok and type(response) == "table" and response.type then
                processQueryResponse(senderID, response)
            end
        end

    elseif event == "monitor_touch" then
        local side, tx, ty = p1, p2, p3
        if handleTouch(tx, ty) then
            needsRedraw = true
        end

    elseif event == "timer" then
        if p1 == redrawTimer then
            needsRedraw = true
            redrawTimer = os.startTimer(2)

        elseif p1 == flashTimer then
            flashState = not flashState
            flashTimer = os.startTimer(0.5)
            if next(activeAlerts) then
                needsRedraw = true
            end

        elseif p1 == discoveryTimer then
            requestResourceList()
            discoveryTimer = os.startTimer(30)
        end
    end

    checkAlerts()

    if needsRedraw then
        drawScreen()
        needsRedraw = false
    end
end
