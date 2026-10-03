local CONTROL_SIDE = "back"
local CONTROL_COLOR = colors.white
local SOLAR_PREFIX = "extrautils_generatorsolar"
local CELL_PREFIX = "cofh_thermalexpansion_energycell"
local SOLAR_CAPACITY = 500000
local CELL_CAPACITY = 50000000
local EMPTY_THRESHOLD = 100
local START_DELAY = 7
local REFRESH_SECONDS = 0.25

local LOCAL_SIDE_ORDER = { "left", "right", "top", "bottom", "front", "back" }

local function findLocalMonitor()
  for _, side in ipairs(LOCAL_SIDE_ORDER) do
    if side ~= CONTROL_SIDE and peripheral.isPresent(side) and peripheral.getType(side) == "monitor" then
      local monitor = peripheral.wrap(side)
      if monitor then
        return side, monitor
      end
    end
  end
  return nil, nil
end

local MON_NAME, mon = findLocalMonitor()
if not mon then
  error("No monitor directly attached to computer")
end

if mon.setTextScale then
  mon.setTextScale(0.5)
end

local function supportsColor(m)
  return m.isColor and m.isColor() or false
end

local IS_COLOR = supportsColor(mon)

local C_BG = colors.black
local C_HEADER = IS_COLOR and colors.lightGray or colors.black
local C_DIV = IS_COLOR and colors.gray or colors.black
local C_INSET = colors.black
local C_ACCENT = IS_COLOR and colors.cyan or colors.white
local C_TEXT = colors.white
local C_MUTED = IS_COLOR and colors.lightGray or colors.white
local C_BRAND = IS_COLOR and colors.blue or colors.white
local C_GOOD = IS_COLOR and colors.lime or colors.white
local C_WARN = IS_COLOR and colors.yellow or colors.white
local C_BAD = IS_COLOR and colors.red or colors.white
local C_BAR_BG = IS_COLOR and colors.gray or colors.black
local C_BAR_SOLAR = IS_COLOR and colors.yellow or colors.white
local C_BAR_CELL = IS_COLOR and colors.cyan or colors.white

local function clamp(n, a, b)
  if n < a then
    return a
  elseif n > b then
    return b
  end
  return n
end

local function round(n)
  return math.floor(n + 0.5)
end

local function formatRF(n)
  n = tonumber(n) or 0
  if n >= 1000000000 then
    return string.format("%.2f GRF", n / 1000000000)
  elseif n >= 1000000 then
    return string.format("%.2f MRF", n / 1000000)
  elseif n >= 1000 then
    return string.format("%.1f kRF", n / 1000)
  end
  return string.format("%d RF", round(n))
end

local function formatRFCompact(n)
  n = tonumber(n) or 0
  if n >= 1000000000 then
    return string.format("%.1fG", n / 1000000000)
  elseif n >= 1000000 then
    return string.format("%.1fM", n / 1000000)
  elseif n >= 1000 then
    return string.format("%.0fk", n / 1000)
  end
  return tostring(round(n))
end

local function formatPercent(value, maximum)
  if not maximum or maximum <= 0 then
    return "0.0%"
  end
  return string.format("%.1f%%", clamp(value / maximum * 100, 0, 100))
end

local function suffixNumber(name)
  local n = tostring(name):match("_(%d+)$")
  return tonumber(n) or math.huge
end

local function naturalPeripheralSort(a, b)
  local an = suffixNumber(a.name)
  local bn = suffixNumber(b.name)
  if an == bn then
    return a.name < b.name
  end
  return an < bn
end

local function hasPrefix(value, prefix)
  if not value then
    return false
  end
  return value == prefix or value:sub(1, #prefix + 1) == prefix .. "_"
end

local function safeCall(name, method, ...)
  if not peripheral.isPresent(name) then
    return nil
  end
  local methods = peripheral.getMethods(name) or {}
  local found = false
  for i = 1, #methods do
    if methods[i] == method then
      found = true
      break
    end
  end
  if not found then
    return nil
  end
  local ok, value = pcall(peripheral.call, name, method, ...)
  if not ok then
    return nil
  end
  if type(value) == "number" then
    return value
  end
  return tonumber(value)
end

local function readEnergy(name)
  local value = safeCall(name, "getEnergyStored", "RF")
  if value == nil then value = safeCall(name, "getEnergyStored") end
  if value == nil then value = safeCall(name, "getEnergy") end
  if value == nil then value = safeCall(name, "getEnergyLevel") end
  if value == nil then value = safeCall(name, "getStoredEnergy") end
  return value
end

local function readCapacity(name, fallback)
  local value = safeCall(name, "getMaxEnergyStored", "RF")
  if value == nil then value = safeCall(name, "getMaxEnergyStored") end
  if value == nil then value = safeCall(name, "getEnergyCapacity") end
  if value == nil then value = safeCall(name, "getMaxEnergyLevel") end
  if value == nil then value = safeCall(name, "getMaxStoredEnergy") end
  if value == nil or value <= 0 then
    value = fallback
  end
  return value
end

local function discover()
  local solars = {}
  local cells = {}
  local names = peripheral.getNames()

  for i = 1, #names do
    local name = names[i]
    local pType = peripheral.getType(name)

    if hasPrefix(name, SOLAR_PREFIX) or hasPrefix(pType, SOLAR_PREFIX) then
      solars[#solars + 1] = { name = name, pType = pType }
    elseif hasPrefix(name, CELL_PREFIX) or hasPrefix(pType, CELL_PREFIX) then
      cells[#cells + 1] = { name = name, pType = pType }
    end
  end

  table.sort(solars, naturalPeripheralSort)
  table.sort(cells, naturalPeripheralSort)

  return solars, cells
end

local function sampleDevices(devices, fallbackCapacity)
  local total = 0
  local capacity = 0
  local readable = 0

  for i = 1, #devices do
    local device = devices[i]
    local stored = readEnergy(device.name)
    local maximum = readCapacity(device.name, fallbackCapacity)

    device.stored = stored
    device.maximum = maximum
    device.readable = stored ~= nil

    if device.readable then
      stored = clamp(stored, 0, maximum)
      device.stored = stored
      total = total + stored
      capacity = capacity + maximum
      readable = readable + 1
    end
  end

  return total, capacity, readable
end

local function getBundledOutput()
  local ok, value = pcall(redstone.getBundledOutput, CONTROL_SIDE)
  if ok and type(value) == "number" then
    return value
  end
  return 0
end

local function setWhiteOutput(enabled)
  local current = getBundledOutput()
  local nextValue

  if enabled then
    nextValue = colors.combine(current, CONTROL_COLOR)
  else
    nextValue = colors.subtract(current, CONTROL_COLOR)
  end

  if nextValue ~= current then
    redstone.setBundledOutput(CONTROL_SIDE, nextValue)
  end
end

local function makeUI(m)
  local cache = {}
  local w, h = m.getSize()

  local function refreshSize()
    local nw, nh = m.getSize()
    if nw ~= w or nh ~= h then
      w, h = nw, nh
      cache = {}
      m.setBackgroundColor(C_BG)
      m.setTextColor(C_TEXT)
      m.clear()
    end
  end

  local function setBg(bg)
    if IS_COLOR then
      m.setBackgroundColor(bg)
    else
      m.setBackgroundColor(colors.black)
    end
  end

  local function setFg(fg)
    if IS_COLOR then
      m.setTextColor(fg)
    else
      m.setTextColor(colors.white)
    end
  end

  local function field(key, x, y, width, value, fg, bg, align)
    if width <= 0 or y < 1 or y > h or x > w then
      return
    end

    local textValue = tostring(value or "")
    if #textValue > width then
      textValue = textValue:sub(1, width)
    end

    local out
    if align == "right" then
      out = string.rep(" ", width - #textValue) .. textValue
    elseif align == "center" then
      local left = math.floor((width - #textValue) / 2)
      local right = width - #textValue - left
      out = string.rep(" ", left) .. textValue .. string.rep(" ", right)
    else
      out = textValue .. string.rep(" ", width - #textValue)
    end

    local sig = out .. "|" .. tostring(fg) .. "|" .. tostring(bg)
    if cache[key] == sig then
      return
    end

    setBg(bg or C_BG)
    setFg(fg or C_TEXT)
    m.setCursorPos(x, y)
    m.write(out)
    cache[key] = sig
  end

  local function fill(key, x, y, width, bg)
    if width <= 0 then
      return
    end
    field(key, x, y, width, "", C_TEXT, bg)
  end

  local function bar(key, x, y, width, value, maximum, fg)
    if width <= 0 then
      return
    end
    local ratio = 0
    if maximum and maximum > 0 then
      ratio = clamp(value / maximum, 0, 1)
    end
    local filled = clamp(round(width * ratio), 0, width)
    fill(key .. "_bg", x, y, width, C_BAR_BG)
    if filled > 0 then
      fill(key .. "_fg", x, y, filled, fg)
    end
    if filled < width then
      fill(key .. "_tail", x + filled, y, width - filled, C_BAR_BG)
    end
  end

  local function line(key, x, y, width, bg)
    fill(key, x, y, width, bg)
  end

  local function clear()
    setBg(C_BG)
    setFg(C_TEXT)
    m.clear()
    cache = {}
  end

  return {
    getWidth = function() return w end,
    getHeight = function() return h end,
    refreshSize = refreshSize,
    field = field,
    fill = fill,
    bar = bar,
    line = line,
    clear = clear
  }
end

local ui = makeUI(mon)
ui.clear()

local function drawHeader()
  local w = ui.getWidth()
  ui.fill("hdr_bg", 1, 1, w, C_HEADER)
  ui.fill("hdr_div", 1, 2, w, C_DIV)
  ui.field("hdr_title", 2, 1, math.max(1, w - 12), "Solar Reserve Controller", C_TEXT, C_HEADER)
  ui.field("hdr_brand", math.max(1, w - 7), 1, math.min(7, w), "ZelOS", C_BRAND, C_HEADER, "right")
end

local function drawBox(prefix, x, y, width, height, title)
  if width < 6 or height < 4 then
    return
  end

  ui.fill(prefix .. "_top", x, y, width, C_DIV)
  ui.fill(prefix .. "_bottom", x, y + height - 1, width, C_DIV)

  for yy = y + 1, y + height - 2 do
    ui.fill(prefix .. "_left_" .. yy, x, yy, 1, C_DIV)
    ui.fill(prefix .. "_right_" .. yy, x + width - 1, yy, 1, C_DIV)
    ui.fill(prefix .. "_inside_" .. yy, x + 1, yy, width - 2, C_INSET)
  end

  ui.fill(prefix .. "_sub", x + 1, y + 1, width - 2, C_HEADER)
  ui.fill(prefix .. "_accent", x + 1, y + 1, 1, C_ACCENT)
  ui.field(prefix .. "_title", x + 3, y + 1, math.max(1, width - 5), title, C_BRAND, C_HEADER)
end

local signalOn = false
local signalStartedAt = nil
local stateText = "CHARGING"
local stateColor = C_GOOD
local lastTopology = ""
local solars = {}
local cells = {}

local function topologySignature()
  local names = peripheral.getNames()
  table.sort(names)
  local parts = {}
  for i = 1, #names do
    local name = names[i]
    local pType = peripheral.getType(name) or ""
    if hasPrefix(name, SOLAR_PREFIX) or hasPrefix(pType, SOLAR_PREFIX) or hasPrefix(name, CELL_PREFIX) or hasPrefix(pType, CELL_PREFIX) then
      parts[#parts + 1] = name .. ":" .. pType
    end
  end
  return table.concat(parts, "|")
end

local function refreshTopology(force)
  local sig = topologySignature()
  if force or sig ~= lastTopology then
    solars, cells = discover()
    lastTopology = sig
    return true
  end
  return false
end

local function updateControl()
  if #solars == 0 then
    if signalOn then
      setWhiteOutput(false)
    end
    signalOn = false
    signalStartedAt = nil
    stateText = "NO SOLAR ARRAY"
    stateColor = C_BAD
    return
  end

  local anyFull = false
  local allEmpty = true
  local anyReadable = false

  for i = 1, #solars do
    local device = solars[i]
    if device.readable then
      anyReadable = true

      if device.stored >= device.maximum then
        anyFull = true
      end

      if device.stored >= EMPTY_THRESHOLD then
        allEmpty = false
      end
    end
  end

  if not anyReadable then
    if signalOn then
      setWhiteOutput(false)
    end
    signalOn = false
    signalStartedAt = nil
    stateText = "SOLAR READ ERROR"
    stateColor = C_BAD
    return
  end

  if not signalOn and anyFull then
    signalOn = true
    signalStartedAt = os.clock()
    setWhiteOutput(true)
  elseif signalOn and allEmpty then
    signalOn = false
    signalStartedAt = nil
    setWhiteOutput(false)
  end

  if signalOn then
    local elapsed = 0
    if signalStartedAt then
      elapsed = os.clock() - signalStartedAt
    end

    if elapsed < START_DELAY then
      stateText = string.format("ARMED  %.1fs", START_DELAY - elapsed)
      stateColor = C_WARN
    else
      stateText = "DISCHARGING"
      stateColor = C_ACCENT
    end
  else
    stateText = "CHARGING"
    stateColor = C_GOOD
  end
end

local function generatorState(device)
  if not device.readable then
    return "ERROR", C_BAD
  end

  if signalOn then
    if device.stored < EMPTY_THRESHOLD then
      return "EMPTY", C_MUTED
    end
    if signalStartedAt and os.clock() - signalStartedAt < START_DELAY then
      return "ARMED", C_WARN
    end
    return "DRAIN", C_ACCENT
  end

  if device.stored >= device.maximum then
    return "FULL", C_WARN
  end

  return "CHARGE", C_GOOD
end

local function drawDashboard(solarTotal, solarCapacity, solarReadable, cellTotal, cellCapacity, cellReadable)
  ui.refreshSize()
  local w = ui.getWidth()
  local h = ui.getHeight()

  drawHeader()

  local margin = 2
  local gap = 1
  local topY = 4
  local summaryH = math.min(9, math.max(9, math.floor(h * 0.28)))
  local availableW = w - margin * 2 - gap
  local leftW = math.floor(availableW / 2)
  local rightW = availableW - leftW
  local leftX = margin
  local rightX = leftX + leftW + gap

  drawBox("solar_summary", leftX, topY, leftW, summaryH, "SOLAR RESERVE")
  drawBox("cell_summary", rightX, topY, rightW, summaryH, "RESONANT STORAGE")

  local sy = topY + 3
  ui.field("solar_count", leftX + 3, sy, leftW - 6, string.format("Online  %d/%d", solarReadable, #solars), C_MUTED, C_INSET)
  ui.field("solar_value", leftX + 3, sy + 1, leftW - 6, "RF  " .. formatRFCompact(solarTotal) .. " / " .. formatRFCompact(solarCapacity), C_TEXT, C_INSET)
  ui.bar("solar_bar", leftX + 3, sy + 3, leftW - 6, solarTotal, solarCapacity, C_BAR_SOLAR)
  ui.field("solar_pct", leftX + 3, sy + 4, leftW - 6, formatPercent(solarTotal, solarCapacity), C_TEXT, C_INSET, "right")

  local cy = topY + 3
  ui.field("cell_count", rightX + 3, cy, rightW - 6, string.format("Online  %d/%d", cellReadable, #cells), C_MUTED, C_INSET)
  ui.field("cell_value", rightX + 3, cy + 1, rightW - 6, "RF  " .. formatRFCompact(cellTotal) .. " / " .. formatRFCompact(cellCapacity), C_TEXT, C_INSET)
  ui.bar("cell_bar", rightX + 3, cy + 3, rightW - 6, cellTotal, cellCapacity, C_BAR_CELL)
  ui.field("cell_pct", rightX + 3, cy + 4, rightW - 6, formatPercent(cellTotal, cellCapacity), C_TEXT, C_INSET, "right")

  local controlY = topY + summaryH + 1
  local listY = controlY + 3
  local bottomY = h - 1

  ui.fill("control_bg", margin, controlY, w - margin * 2, 2, C_HEADER)
  ui.fill("control_accent", margin, controlY, 1, 2, C_ACCENT)
  ui.field("control_label", margin + 2, controlY, 18, "WHITE / BACK", C_MUTED, C_HEADER)
  ui.field("control_state", margin + 21, controlY, math.max(1, w - margin * 2 - 23), stateText, stateColor, C_HEADER, "right")
  ui.field("control_detail", margin + 2, controlY + 1, w - margin * 2 - 3, signalOn and "Bundled output ON" or "Bundled output OFF", C_TEXT, C_HEADER)

  if listY <= bottomY then
    local listHeight = bottomY - listY + 1
    local columns = 1
    if w >= 50 then
      columns = 2
    end

    local colGap = 1
    local usable = w - margin * 2 - (columns - 1) * colGap
    local colW = math.floor(usable / columns)
    local rowsPerCol = math.max(1, listHeight - 2)
    local visible = rowsPerCol * columns

    ui.fill("list_title_bg", margin, listY, w - margin * 2, 1, C_HEADER)
    ui.fill("list_title_accent", margin, listY, 1, 1, C_ACCENT)
    ui.field("list_title", margin + 2, listY, w - margin * 2 - 3, "SOLAR GENERATORS", C_BRAND, C_HEADER)

    for slot = 1, visible do
      local col = math.floor((slot - 1) / rowsPerCol)
      local row = (slot - 1) % rowsPerCol
      local x = margin + col * (colW + colGap)
      local y = listY + 1 + row
      local device = solars[slot]

      if device then
        local stored = device.stored or 0
        local maximum = device.maximum or SOLAR_CAPACITY
        local label = "G" .. tostring(suffixNumber(device.name))
        if suffixNumber(device.name) == math.huge then
          label = "G" .. tostring(slot)
        end
        local status, statusColor = generatorState(device)
        local pct = device.readable and formatPercent(stored, maximum) or "--"
        local value = device.readable and formatRFCompact(stored) or "ERR"

        local stateW = 6
        local valueW = 6
        local pctW = 7
        local labelW = math.max(3, colW - stateW - valueW - pctW - 3)
        local pctX = x + labelW + 1
        local valueX = pctX + pctW + 1
        local stateX = valueX + valueW + 1

        ui.field("g_label_" .. slot, x, y, labelW, label, C_ACCENT, C_INSET)
        ui.field("g_pct_" .. slot, pctX, y, pctW, pct, C_TEXT, C_INSET, "right")
        ui.field("g_value_" .. slot, valueX, y, valueW, value, C_MUTED, C_INSET, "right")
        ui.field("g_state_" .. slot, stateX, y, stateW, status, statusColor, C_INSET, "right")
      else
        ui.field("g_clear_" .. slot, x, y, colW, "", C_TEXT, C_INSET)
      end
    end

    if #solars > visible then
      ui.field("g_more", margin + 2, bottomY, w - margin * 2 - 3, "+" .. tostring(#solars - visible) .. " additional generators", C_WARN, C_INSET, "right")
    else
      ui.field("g_more", margin + 2, bottomY, w - margin * 2 - 3, "", C_WARN, C_INSET, "right")
    end
  end
end

setWhiteOutput(false)
refreshTopology(true)

local refreshTimer = os.startTimer(0)

while true do
  local event, a = os.pullEventRaw()

  if event == "terminate" then
    setWhiteOutput(false)
    ui.clear()
    drawHeader()
    ui.field("stopped", 2, 4, math.max(1, ui.getWidth() - 3), "Controller stopped - output disabled", C_WARN, C_BG)
    return
  elseif event == "timer" and a == refreshTimer then
    refreshTopology(false)

    local solarTotal, solarCapacity, solarReadable = sampleDevices(solars, SOLAR_CAPACITY)
    local cellTotal, cellCapacity, cellReadable = sampleDevices(cells, CELL_CAPACITY)

    updateControl()
    drawDashboard(solarTotal, solarCapacity, solarReadable, cellTotal, cellCapacity, cellReadable)

    refreshTimer = os.startTimer(REFRESH_SECONDS)
  elseif event == "peripheral" or event == "peripheral_detach" then
    refreshTopology(true)
  elseif event == "monitor_resize" and a == MON_NAME then
    ui.clear()
  end
end
