local CONTROL_SIDE = "back"
local SOLAR_PREFIX = "extrautils_generatorsolar"
local CELL_PREFIX = "cofh_thermalexpansion_energycell"
local SOLAR_CAPACITY = 500000
local CELL_CAPACITY = 50000000
local EMPTY_THRESHOLD = 100
local START_DELAY = 7
local REFRESH_SECONDS = 0.5
local MONITOR_NAME = nil

local SIDES = { "left", "right", "top", "bottom", "front", "back" }

local function clamp(n, a, b)
  if n < a then return a end
  if n > b then return b end
  return n
end

local function fmtFixed(n, digits)
  n = tonumber(n) or 0
  digits = math.max(0, math.floor(tonumber(digits) or 0))
  if n ~= n or n == math.huge or n == -math.huge then return "0" end
  local scale = 1
  for i = 1, digits do scale = scale * 10 end
  local scaled
  if n >= 0 then
    scaled = math.floor(n * scale + 0.5)
  else
    scaled = math.ceil(n * scale - 0.5)
  end
  local negative = scaled < 0
  if negative then scaled = -scaled end
  local whole = math.floor(scaled / scale)
  local sign = negative and "-" or ""
  if digits == 0 then return sign .. tostring(whole) end
  local frac = math.floor(scaled - whole * scale)
  if frac == 0 then return sign .. tostring(whole) end
  local fracText = tostring(frac)
  while #fracText < digits do fracText = "0" .. fracText end
  fracText = fracText:gsub("0+$", "")
  return sign .. tostring(whole) .. "." .. fracText
end

local function fmtPct(n)
  return fmtFixed(n, 1) .. "%"
end

local function formatRF(n)
  n = tonumber(n) or 0
  local a = math.abs(n)
  if a >= 1000000000 then return fmtFixed(n / 1000000000, 2) .. " GRF" end
  if a >= 1000000 then return fmtFixed(n / 1000000, 1) .. " MRF" end
  if a >= 1000 then return fmtFixed(n / 1000, 1) .. " KRF" end
  return fmtFixed(n, 0) .. " RF"
end

local function centerText(text, width)
  text = tostring(text or "")
  if width <= 0 then return "" end
  if #text > width then
    if width <= 3 then return text:sub(1, width) end
    text = text:sub(1, width - 3) .. "..."
  end
  local left = math.floor((width - #text) / 2)
  local right = width - #text - left
  return string.rep(" ", left) .. text .. string.rep(" ", right)
end

local function startsWith(value, prefix)
  if type(value) ~= "string" then return false end
  return value == prefix or value:sub(1, #prefix + 1) == prefix .. "_"
end

local function suffixNumber(name)
  local n = tostring(name):match("_(%d+)$")
  return tonumber(n)
end

local function findWiredModems()
  local found = {}
  for i = 1, #SIDES do
    local side = SIDES[i]
    if peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
      local modem = peripheral.wrap(side)
      if modem and modem.getNamesRemote then
        local ok, names = pcall(modem.getNamesRemote)
        if ok and type(names) == "table" then
          found[#found + 1] = {
            side = side,
            modem = modem,
            names = names
          }
        end
      end
    end
  end
  return found
end

local function getAllPeripheralNames(modems)
  local seen = {}
  local names = {}

  local ok, attached = pcall(peripheral.getNames)
  if ok and type(attached) == "table" then
    for i = 1, #attached do
      local name = attached[i]
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end

  for i = 1, #modems do
    local remote = modems[i].names
    for j = 1, #remote do
      local name = remote[j]
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end

  table.sort(names)
  return names
end

local function getPeripheralType(name, modems)
  local ok, pType = pcall(peripheral.getType, name)
  if ok and pType then return pType end

  for i = 1, #modems do
    local modem = modems[i].modem
    if modem and modem.getTypeRemote then
      local typeOk, remoteType = pcall(modem.getTypeRemote, name)
      if typeOk and remoteType then return remoteType end
    end
  end

  return nil
end

local function safeWrap(name)
  local ok, wrapped = pcall(peripheral.wrap, name)
  if ok then return wrapped end
  return nil
end

local function findMonitor(names, modems)
  if MONITOR_NAME then
    if getPeripheralType(MONITOR_NAME, modems) == "monitor" then
      return MONITOR_NAME, safeWrap(MONITOR_NAME)
    end
    return nil, nil
  end

  local bestName = nil
  local bestMonitor = nil
  local bestArea = -1

  for i = 1, #names do
    local name = names[i]
    if getPeripheralType(name, modems) == "monitor" then
      local monitor = safeWrap(name)
      if monitor and monitor.getSize then
        local ok, w, h = pcall(monitor.getSize)
        if ok and type(w) == "number" and type(h) == "number" then
          local area = w * h
          if area > bestArea then
            bestArea = area
            bestName = name
            bestMonitor = monitor
          end
        end
      end
    end
  end

  return bestName, bestMonitor
end

local function safePeripheralCall(name, method, ...)
  local ok, value = pcall(peripheral.call, name, method, ...)
  if not ok then return nil end
  if type(value) == "number" then return value end
  return tonumber(value)
end

local function readEnergy(name)
  local value = safePeripheralCall(name, "getEnergyStored", "RF")
  if value == nil then value = safePeripheralCall(name, "getEnergyStored") end
  if value == nil then value = safePeripheralCall(name, "getEnergy") end
  if value == nil then value = safePeripheralCall(name, "getStoredEnergy") end
  if value == nil then value = safePeripheralCall(name, "getEnergyLevel") end
  return value
end

local function readCapacity(name, fallback)
  local value = safePeripheralCall(name, "getMaxEnergyStored", "RF")
  if value == nil then value = safePeripheralCall(name, "getMaxEnergyStored") end
  if value == nil then value = safePeripheralCall(name, "getEnergyCapacity") end
  if value == nil then value = safePeripheralCall(name, "getMaxStoredEnergy") end
  if value == nil then value = safePeripheralCall(name, "getMaxEnergyLevel") end
  if value == nil or value <= 0 then return fallback end
  return value
end

local function discoverDevices(names, modems)
  local solars = {}
  local cells = {}

  for i = 1, #names do
    local name = names[i]
    local pType = getPeripheralType(name, modems)

    if startsWith(name, SOLAR_PREFIX) or startsWith(pType, SOLAR_PREFIX) then
      solars[#solars + 1] = { name = name, pType = pType }
    elseif startsWith(name, CELL_PREFIX) or startsWith(pType, CELL_PREFIX) then
      cells[#cells + 1] = { name = name, pType = pType }
    end
  end

  local function sorter(a, b)
    local an = suffixNumber(a.name)
    local bn = suffixNumber(b.name)

    if an and bn and an ~= bn then return an < bn end
    if an and not bn then return true end
    if bn and not an then return false end
    return a.name < b.name
  end

  table.sort(solars, sorter)
  table.sort(cells, sorter)

  return solars, cells
end

local function sampleDevices(devices, fallbackCapacity)
  local total = 0
  local capacity = 0
  local readable = 0
  local full = 0
  local empty = 0

  for i = 1, #devices do
    local device = devices[i]
    local stored = readEnergy(device.name)
    local maximum = readCapacity(device.name, fallbackCapacity)

    device.maximum = maximum
    device.stored = stored
    device.readable = stored ~= nil

    if device.readable then
      device.stored = clamp(stored, 0, maximum)
      total = total + device.stored
      capacity = capacity + maximum
      readable = readable + 1

      if device.stored >= maximum then
        full = full + 1
      end

      if device.stored < EMPTY_THRESHOLD then
        empty = empty + 1
      end
    end
  end

  return {
    total = total,
    capacity = capacity,
    readable = readable,
    count = #devices,
    full = full,
    empty = empty,
    pct = capacity > 0 and clamp(total / capacity * 100, 0, 100) or 0
  }
end

local controlOutputOk = true

local function setControlOutput(enabled)
  local ok = pcall(redstone.setOutput, CONTROL_SIDE, enabled)
  if not ok then
    controlOutputOk = false
    return false
  end

  local readOk, state = pcall(redstone.getOutput, CONTROL_SIDE)
  if readOk then
    controlOutputOk = state == enabled
  else
    controlOutputOk = true
  end

  return controlOutputOk
end

local function supportsColor(m)
  return m.isColor and m.isColor() or false
end

local function makeUI(m)
  local w, h = m.getSize()
  local total = w * h
  local isColor = supportsColor(m)
  local frameChars = {}
  local frameFg = {}
  local frameBg = {}
  local prevChars = {}
  local prevFg = {}
  local prevBg = {}

  local C_BG = colors.black
  local C_HEADER = isColor and colors.lightGray or colors.black
  local C_DIV = isColor and colors.gray or colors.black
  local C_INSET = colors.black
  local C_ACCENT = isColor and colors.cyan or colors.white
  local C_TEXT = colors.white
  local C_MUTED = isColor and colors.lightGray or colors.white
  local C_BRAND = isColor and colors.blue or colors.white
  local C_OK = isColor and colors.lime or colors.white
  local C_WARN = isColor and colors.yellow or colors.white
  local C_BAD = isColor and colors.red or colors.white
  local C_ACTION = isColor and colors.green or colors.white
  local C_ENERGY = isColor and colors.blue or colors.white
  local C_SOLAR = isColor and colors.yellow or colors.white
  local C_ORANGE = isColor and colors.orange or colors.white

  local function indexOf(x, y)
    return (y - 1) * w + x
  end

  local function setBg(bg)
    if isColor then m.setBackgroundColor(bg) else m.setBackgroundColor(colors.black) end
  end

  local function setFg(fg)
    if isColor then m.setTextColor(fg) else m.setTextColor(colors.white) end
  end

  local function beginFrame()
    frameChars = {}
    frameFg = {}
    frameBg = {}
    for i = 1, total do
      frameChars[i] = " "
      frameFg[i] = C_TEXT
      frameBg[i] = C_BG
    end
  end

  local function rect(x, y, ww, hh, bg)
    if ww <= 0 or hh <= 0 then return end
    local x1 = clamp(x, 1, w)
    local y1 = clamp(y, 1, h)
    local x2 = clamp(x + ww - 1, 1, w)
    local y2 = clamp(y + hh - 1, 1, h)
    if x2 < x1 or y2 < y1 then return end

    for yy = y1, y2 do
      for xx = x1, x2 do
        local i = indexOf(xx, yy)
        frameChars[i] = " "
        frameFg[i] = C_TEXT
        frameBg[i] = bg
      end
    end
  end

  local function fitText(s, width)
    s = tostring(s or "")
    if width <= 0 then return "" end
    if #s <= width then return s end
    if width <= 3 then return s:sub(1, width) end
    return s:sub(1, width - 3) .. "..."
  end

  local function field(key, x, y, ww, s, fg, bg)
    if ww <= 0 or y < 1 or y > h or x > w or x + ww - 1 < 1 then return end
    local x1 = clamp(x, 1, w)
    local x2 = clamp(x + ww - 1, 1, w)
    local visibleW = x2 - x1 + 1
    if visibleW <= 0 then return end

    s = tostring(s or "")
    if x < 1 then s = s:sub(2 - x) end
    s = fitText(s, visibleW)
    local out = s .. string.rep(" ", visibleW - #s)
    local useFg = fg or C_TEXT
    local useBg = bg or C_BG

    for n = 1, visibleW do
      local i = indexOf(x1 + n - 1, y)
      frameChars[i] = out:sub(n, n)
      frameFg[i] = useFg
      frameBg[i] = useBg
    end
  end

  local function invalidate()
    prevChars = {}
    prevFg = {}
    prevBg = {}
  end

  local function flush(force)
    for y = 1, h do
      local x = 1
      while x <= w do
        local i = indexOf(x, y)
        local changed = force or prevChars[i] ~= frameChars[i] or prevFg[i] ~= frameFg[i] or prevBg[i] ~= frameBg[i]

        if changed then
          local fg = frameFg[i]
          local bg = frameBg[i]
          local startX = x
          local chars = {}

          while x <= w do
            local j = indexOf(x, y)
            local cellChanged = force or prevChars[j] ~= frameChars[j] or prevFg[j] ~= frameFg[j] or prevBg[j] ~= frameBg[j]
            if not cellChanged or frameFg[j] ~= fg or frameBg[j] ~= bg then break end

            chars[#chars + 1] = frameChars[j]
            prevChars[j] = frameChars[j]
            prevFg[j] = frameFg[j]
            prevBg[j] = frameBg[j]
            x = x + 1
          end

          setBg(bg)
          setFg(fg)
          m.setCursorPos(startX, y)
          m.write(table.concat(chars))
        else
          x = x + 1
        end
      end
    end
  end

  beginFrame()

  return {
    w = w,
    h = h,
    C_BG = C_BG,
    C_HEADER = C_HEADER,
    C_DIV = C_DIV,
    C_INSET = C_INSET,
    C_ACCENT = C_ACCENT,
    C_TEXT = C_TEXT,
    C_MUTED = C_MUTED,
    C_BRAND = C_BRAND,
    C_OK = C_OK,
    C_WARN = C_WARN,
    C_BAD = C_BAD,
    C_ACTION = C_ACTION,
    C_ENERGY = C_ENERGY,
    C_SOLAR = C_SOLAR,
    C_ORANGE = C_ORANGE,
    beginFrame = beginFrame,
    rect = rect,
    field = field,
    flush = flush,
    invalidate = invalidate,
    fitText = fitText
  }
end

local function drawZelusLogo(ui, x, y, w, h)
  if w < 8 or h < 8 then return end

  local gray = colors.gray
  local blue = colors.blue
  local lightBlue = colors.lightBlue
  local brown = colors.brown
  local orange = colors.orange
  local yellow = colors.yellow
  local red = colors.red
  local pink = colors.pink
  local white = colors.white

  local pattern = {
    ".....KK......KK.....",
    "....KBBK....KBBK....",
    "...KBBbK....KbBBK...",
    "...KBBBKKDDKKBBBK...",
    "...KKBBdDYYDdBBKK...",
    "...KRPPRPDDRRPPRK...",
    "...KRddddRRddddRK...",
    "..KKRDYOoRRoOYDRKK..",
    "..KKPPRRDPRDRRPPKK..",
    "KKKKRRPPPPrPPPRRKKKK",
    "KWWWYOWWWWWWWWOYWWWK",
    ".KKKKKBrrDDrrBKKKKK.",
    "...KKBKKrrrrKKBKK...",
    "...KBbKKKYYKKKbBK...",
    "....KKKKKWWKKKKK....",
    ".....KKK.KK.KKK.....",
  }

  local palette = {
    K = gray,
    B = blue,
    b = lightBlue,
    D = brown,
    d = brown,
    O = orange,
    o = orange,
    Y = yellow,
    R = red,
    P = pink,
    r = red,
    W = white
  }

  ui.rect(x, y, w, h, ui.C_INSET)

  local artH = math.min(#pattern, math.max(1, h - 1))
  local drawY = y + math.max(0, math.floor((h - 1 - artH) / 2))

  for row = 1, artH do
    local line = pattern[row]
    local lineW = #line
    local visibleW = math.min(lineW, w)
    local drawX = x + math.floor((w - visibleW) / 2)
    local srcStart = 1

    if lineW > w then
      srcStart = math.floor((lineW - w) / 2) + 1
    end

    for col = 1, visibleW do
      local ch = line:sub(srcStart + col - 1, srcStart + col - 1)
      local color = palette[ch]
      if color then ui.rect(drawX + col - 1, drawY + row - 1, 1, 1, color) end
    end
  end

  ui.field("logo_name", x, y + h - 1, w, centerText("ZELUS", w), orange, ui.C_INSET)
end

local function cardSurface(ui, x, y, ww, hh, accentColor)
  if ww < 4 or hh < 3 then return end
  ui.rect(x, y, ww, hh, ui.C_BG)
  ui.rect(x, y, ww, 1, ui.C_DIV)
  ui.rect(x, y + hh - 1, ww, 1, ui.C_DIV)
  ui.rect(x, y, 1, hh, ui.C_DIV)
  ui.rect(x + ww - 1, y, 1, hh, ui.C_DIV)
  ui.rect(x + 1, y + 1, ww - 2, hh - 2, ui.C_INSET)
  ui.rect(x + 1, y + 1, 1, hh - 2, accentColor or ui.C_ACCENT)
end

local function sectionTitle(ui, key, x, y, ww, title)
  ui.field(key, x + 3, y, math.max(0, ww - 5), string.upper(title or ""), ui.C_TEXT, ui.C_DIV)
end

local function kv(ui, key, x, y, width, label, value, valueColor)
  if width <= 0 then return end

  local labelText = string.upper(tostring(label or "")) .. ":"
  local valueText = tostring(value or "")
  local labelW = math.min(#labelText, width)

  if #labelText + 1 + #valueText > width and width >= 8 then
    local valueNeed = math.min(#valueText, math.max(3, math.floor(width * 0.58)))
    labelW = math.min(#labelText, math.max(3, width - valueNeed - 1))
  end

  ui.field(key .. "_l", x, y, labelW, labelText, ui.C_MUTED, ui.C_INSET)

  local avail = width - labelW - 1
  if avail > 0 then
    ui.field(key .. "_v", x + labelW + 1, y, avail, valueText, valueColor or ui.C_TEXT, ui.C_INSET)
  end
end

local function drawBar(ui, x, y, width, percent, fillColor)
  if width <= 0 then return end
  percent = clamp(percent or 0, 0, 100)
  local filled = clamp(math.floor(width * percent / 100 + 0.5), 0, width)

  if filled > 0 then ui.rect(x, y, filled, 1, fillColor) end
  if width - filled > 0 then ui.rect(x + filled, y, width - filled, 1, ui.C_DIV) end
end

local function drawStatCard(ui, key, x, y, ww, hh, title, accent, items)
  cardSurface(ui, x, y, ww, hh, accent)
  sectionTitle(ui, key .. "_title", x, y, ww, title)

  local startY = y + 2
  local usableRows = hh - 3

  for i = 1, math.min(#items, usableRows) do
    local item = items[i]
    kv(ui, key .. "_" .. i, x + 3, startY + i - 1, ww - 5, item[1], item[2], item[3])
  end
end

local function drawMeterCard(ui, key, x, y, ww, hh, title, label, detail, pct, fillColor)
  cardSurface(ui, x, y, ww, hh, ui.C_ACCENT)
  sectionTitle(ui, key .. "_title", x, y, ww, title)

  local innerW = ww - 5
  local leftW = math.floor(innerW * 0.40)

  ui.field(key .. "_label", x + 3, y + 2, leftW, string.upper(label), ui.C_MUTED, ui.C_INSET)
  ui.field(key .. "_detail", x + 3 + leftW, y + 2, innerW - leftW, detail, ui.C_TEXT, ui.C_INSET)
  drawBar(ui, x + 2, y + 3, ww - 4, pct, fillColor)
end

local function percentColor(ui, pct)
  if pct < 20 then return ui.C_BAD end
  if pct < 70 then return ui.C_WARN end
  return ui.C_OK
end

local function printStartup(modems, monitorName, mon, solars, cells)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)

  print("ZelOS Solar Reserve Controller")
  print("------------------------------")

  if #modems == 0 then
    print("Wired modem: none detected")
  else
    local sides = {}
    for i = 1, #modems do
      sides[#sides + 1] = modems[i].side
    end
    print("Wired modem: " .. table.concat(sides, ", "))
  end

  print("Monitor: " .. tostring(monitorName or "not found"))

  if mon and mon.getSize then
    local ok, w, h = pcall(mon.getSize)
    if ok then print("Monitor size: " .. tostring(w) .. "x" .. tostring(h)) end
  end

  print("Solar generators: " .. tostring(#solars))
  print("Energy cells: " .. tostring(#cells))
  print("Control: rear standard redstone")
  print("RedNet cable face: white")
  print("")
end

local function main()
  local modems = findWiredModems()
  local names = getAllPeripheralNames(modems)
  local monitorName, mon = findMonitor(names, modems)
  local solars, cells = discoverDevices(names, modems)

  if mon and mon.setTextScale then
    pcall(mon.setTextScale, 0.5)
  end

  printStartup(modems, monitorName, mon, solars, cells)

  if #modems == 0 then
    printError("No wired modem with remote peripheral support was found.")
    return
  end

  if not mon then
    printError("No monitor was found on the wired peripheral network.")
    return
  end

  local W, H = mon.getSize()

  if W < 70 or H < 45 then
    printError("Monitor is too small for the 3x3 ZelOS layout at scale 0.5.")
    print("Detected: " .. tostring(W) .. "x" .. tostring(H))
    return
  end

  local ui = makeUI(mon)
  local NAV_W = math.max(18, math.min(22, math.floor(W * 0.20)))
  local CONTENT_X = NAV_W + 2
  local CONTENT_W = W - CONTENT_X
  local CONTENT_TOP = 4
  local CONTENT_BOTTOM = H - 1
  local lastNameSignature = table.concat(names, "|")
  local signalOn = false
  local signalStartedAt = nil
  local stateText = "STORING POWER"
  local stateColor = ui.C_OK
  local forceFullRedraw = true

  local function refreshDiscovery()
    local newModems = findWiredModems()
    local newNames = getAllPeripheralNames(newModems)
    local newSig = table.concat(newNames, "|")

    if newSig ~= lastNameSignature then
      modems = newModems
      names = newNames
      solars, cells = discoverDevices(names, modems)
      lastNameSignature = newSig
    end
  end

  local function updateControl()
    if #solars == 0 then
      signalOn = false
      signalStartedAt = nil
      setControlOutput(false)
      stateText = "NO SOLAR ARRAY"
      stateColor = ui.C_BAD
      return
    end

    local anyFull = false
    local allEmpty = true
    local allReadable = true

    for i = 1, #solars do
      local device = solars[i]

      if not device.readable then
        allReadable = false
      else
        if device.stored >= device.maximum then anyFull = true end
        if device.stored >= EMPTY_THRESHOLD then allEmpty = false end
      end
    end

    if not allReadable then
      signalOn = false
      signalStartedAt = nil
      setControlOutput(false)
      stateText = "SOLAR READ ERROR"
      stateColor = ui.C_BAD
      return
    end

    if not signalOn and anyFull then
      signalOn = true
      signalStartedAt = os.clock()

      if not setControlOutput(true) then
        signalOn = false
        signalStartedAt = nil
        stateText = "SIGNAL ERROR"
        stateColor = ui.C_BAD
        return
      end
    elseif signalOn and allEmpty then
      signalOn = false
      signalStartedAt = nil

      if not setControlOutput(false) then
        stateText = "SIGNAL ERROR"
        stateColor = ui.C_BAD
        return
      end
    end

    if not controlOutputOk then
      stateText = "SIGNAL ERROR"
      stateColor = ui.C_BAD
    elseif signalOn then
      local elapsed = os.clock() - signalStartedAt
      if elapsed < START_DELAY then
        stateText = "START DELAY " .. fmtFixed(START_DELAY - elapsed, 1) .. " S"
        stateColor = ui.C_WARN
      else
        stateText = "TRANSFER ACTIVE"
        stateColor = ui.C_ACTION
      end
    else
      stateText = "STORING POWER"
      stateColor = ui.C_OK
    end
  end

  local function generatorState(device)
    if not device.readable then return "ERROR", ui.C_BAD end

    if signalOn then
      if device.stored < EMPTY_THRESHOLD then return "EMPTY", ui.C_MUTED end
      if signalStartedAt and os.clock() - signalStartedAt < START_DELAY then return "WAIT", ui.C_WARN end
      return "DRAIN", ui.C_ACCENT
    end

    if device.stored >= device.maximum then return "FULL", ui.C_WARN end
    return "STORE", ui.C_OK
  end

  local function drawHeader()
    ui.rect(1, 1, W, 1, ui.C_HEADER)
    ui.rect(1, 2, W, 1, ui.C_DIV)

    local title = "Solar Reserve Control v1.1"
    ui.field("hdr_title", 1 + math.floor((W - #title) / 2), 1, #title, title, ui.C_TEXT, ui.C_HEADER)
    ui.field("hdr_brand", W - 5, 1, 5, "ZelOS", ui.C_BRAND, ui.C_HEADER)
  end

  local function drawTaskbar(solarBank, cellBank)
    ui.rect(1, 3, NAV_W, H - 2, ui.C_DIV)
    ui.rect(2, 3, NAV_W - 2, H - 2, ui.C_INSET)
    ui.rect(NAV_W, 3, 1, H - 2, ui.C_ACCENT)

    local logoH = H >= 50 and 18 or 14
    drawZelusLogo(ui, 2, 4, NAV_W - 2, logoH)

    local tabY = 5 + logoH
    ui.rect(3, tabY, NAV_W - 5, 2, ui.C_BRAND)
    ui.field("nav_overview", 3, tabY + 1, NAV_W - 5, centerText("OVERVIEW", NAV_W - 5), ui.C_TEXT, ui.C_BRAND)

    local statusTop = H - 11
    ui.field("nav_status_title", 3, statusTop, NAV_W - 5, "SYSTEM STATUS", ui.C_MUTED, ui.C_INSET)
    ui.field("nav_auto", 3, statusTop + 2, NAV_W - 5, "AUTO ENABLED", ui.C_OK, ui.C_INSET)
    ui.field("nav_array", 3, statusTop + 3, NAV_W - 5, "ARRAY " .. solarBank.readable .. "/" .. solarBank.count, solarBank.readable == solarBank.count and ui.C_OK or ui.C_WARN, ui.C_INSET)
    ui.field("nav_cells", 3, statusTop + 4, NAV_W - 5, "CELLS " .. cellBank.readable .. "/" .. cellBank.count, cellBank.readable == cellBank.count and ui.C_OK or ui.C_WARN, ui.C_INSET)
    ui.field("nav_rednet", 3, statusTop + 5, NAV_W - 5, controlOutputOk and "REDNET READY" or "REDNET ERROR", controlOutputOk and ui.C_OK or ui.C_BAD, ui.C_INSET)
    ui.field("nav_output", 3, statusTop + 6, NAV_W - 5, signalOn and "OUTPUT ACTIVE" or "OUTPUT IDLE", signalOn and ui.C_ACTION or ui.C_MUTED, ui.C_INSET)
    ui.field("nav_solar_pct", 3, statusTop + 8, NAV_W - 5, "SOLAR " .. fmtPct(solarBank.pct), percentColor(ui, solarBank.pct), ui.C_INSET)
    ui.field("nav_cell_pct", 3, statusTop + 9, NAV_W - 5, "CELLS " .. fmtPct(cellBank.pct), percentColor(ui, cellBank.pct), ui.C_INSET)
  end

  local function drawGeneratorBank(x, y, ww, hh)
    cardSurface(ui, x, y, ww, hh, ui.C_ACCENT)
    sectionTitle(ui, "gens_title", x, y, ww, "SOLAR GENERATORS")

    local innerX = x + 3
    local innerY = y + 2
    local innerW = ww - 5
    local innerH = hh - 3
    local gap = 2
    local leftW = math.floor((innerW - gap) / 2)
    local rightX = innerX + leftW + gap
    local rightW = innerW - gap - leftW
    local rowsPerColumn = math.max(1, math.floor(innerH / 2))
    local visible = rowsPerColumn * 2

    if #solars == 0 then
      ui.field("gens_none", innerX, innerY, innerW, "NO SOLAR GENERATORS DETECTED", ui.C_BAD, ui.C_INSET)
      return
    end

    for slot = 1, visible do
      local col = slot > rowsPerColumn and 1 or 0
      local row = col == 0 and slot - 1 or slot - rowsPerColumn - 1
      local gx = col == 0 and innerX or rightX
      local gw = col == 0 and leftW or rightW
      local gy = innerY + row * 2
      local device = solars[slot]

      if device then
        local number = suffixNumber(device.name) or slot
        local state, stateColor = generatorState(device)
        local pct = device.readable and clamp(device.stored / device.maximum * 100, 0, 100) or 0
        local label = "GEN " .. string.format("%02d", number)
        local amount = device.readable and formatRF(device.stored) or "UNREADABLE"
        local pctText = device.readable and fmtPct(pct) or "--"

        ui.field("gen_label_" .. slot, gx, gy, 8, label, ui.C_ACCENT, ui.C_INSET)
        ui.field("gen_amount_" .. slot, gx + 9, gy, math.max(1, gw - 21), amount, ui.C_TEXT, ui.C_INSET)
        ui.field("gen_pct_" .. slot, gx + math.max(9, gw - 12), gy, 6, pctText, ui.C_MUTED, ui.C_INSET)
        ui.field("gen_state_" .. slot, gx + math.max(15, gw - 5), gy, 5, state, stateColor, ui.C_INSET)

        local barWidth = math.max(1, gw - 7)
        drawBar(ui, gx, gy + 1, barWidth, pct, ui.C_SOLAR)
        ui.field("gen_state2_" .. slot, gx + barWidth + 1, gy + 1, math.max(1, gw - barWidth - 1), state, stateColor, ui.C_INSET)
      end
    end

    if #solars > visible then
      ui.field("gens_more", innerX, y + hh - 2, innerW, "+" .. tostring(#solars - visible) .. " ADDITIONAL GENERATORS", ui.C_WARN, ui.C_INSET)
    end
  end

  local function drawDashboard(solarBank, cellBank)
    ui.beginFrame()
    drawHeader()
    drawTaskbar(solarBank, cellBank)

    local outerX = CONTENT_X
    local outerW = CONTENT_W
    local gap = 1
    local topH = 7
    local meterH = 5
    local leftW = math.floor((outerW - 2) / 2)
    local rightX = outerX + leftW + 2
    local rightW = outerW - leftW - 2

    local arrayColor = solarBank.readable == solarBank.count and ui.C_ACCENT or ui.C_WARN
    local transferColor = stateColor

    drawStatCard(ui, "array", outerX, CONTENT_TOP, leftW, topH, "ARRAY STATUS", arrayColor, {
      { "ONLINE", tostring(solarBank.readable) .. " / " .. tostring(solarBank.count), solarBank.readable == solarBank.count and ui.C_OK or ui.C_WARN },
      { "AVERAGE", fmtPct(solarBank.pct), percentColor(ui, solarBank.pct) },
      { "FULL UNITS", tostring(solarBank.full), solarBank.full > 0 and ui.C_WARN or ui.C_MUTED },
      { "EMPTY UNITS", tostring(solarBank.empty), solarBank.empty > 0 and ui.C_MUTED or ui.C_TEXT }
    })

    drawStatCard(ui, "transfer", rightX, CONTENT_TOP, rightW, topH, "TRANSFER CONTROL", transferColor, {
      { "MODE", "AUTOMATIC", ui.C_ACCENT },
      { "STATE", stateText, stateColor },
      { "SIGNAL", signalOn and "REAR OUTPUT ON" or "REAR OUTPUT OFF", signalOn and ui.C_ACTION or ui.C_MUTED },
      { "REDNET", "WHITE / " .. tostring(START_DELAY) .. " S DELAY", ui.C_TEXT }
    })

    local solarMeterY = CONTENT_TOP + topH + gap
    drawMeterCard(
      ui,
      "solar_meter",
      outerX,
      solarMeterY,
      outerW,
      meterH,
      "SOLAR RESERVE",
      "ARRAY STORAGE",
      formatRF(solarBank.total) .. " / " .. formatRF(solarBank.capacity) .. "   " .. fmtPct(solarBank.pct),
      solarBank.pct,
      ui.C_SOLAR
    )

    local cellMeterY = solarMeterY + meterH + gap
    drawMeterCard(
      ui,
      "cell_meter",
      outerX,
      cellMeterY,
      outerW,
      meterH,
      "RESONANT ENERGY BANK",
      tostring(cellBank.readable) .. "/" .. tostring(cellBank.count) .. " CELLS ONLINE",
      formatRF(cellBank.total) .. " / " .. formatRF(cellBank.capacity) .. "   " .. fmtPct(cellBank.pct),
      cellBank.pct,
      ui.C_ENERGY
    )

    local generatorY = cellMeterY + meterH + gap
    local generatorH = CONTENT_BOTTOM - generatorY + 1

    if generatorH >= 5 then
      drawGeneratorBank(outerX, generatorY, outerW, generatorH)
    end

    ui.flush(forceFullRedraw)
    forceFullRedraw = false
  end

  local function tick()
    refreshDiscovery()

    local solarBank = sampleDevices(solars, SOLAR_CAPACITY)
    local cellBank = sampleDevices(cells, CELL_CAPACITY)

    updateControl()
    drawDashboard(solarBank, cellBank)
  end

  setControlOutput(false)
  tick()

  print("Running.")
  print("Monitor: " .. tostring(monitorName))
  print("Display: " .. tostring(W) .. "x" .. tostring(H))
  print("Press Ctrl+T to stop safely.")

  local timer = os.startTimer(REFRESH_SECONDS)

  while true do
    local event, a = os.pullEventRaw()

    if event == "terminate" then
      setControlOutput(false)
      print("")
      print("Stopped. Rear redstone output disabled.")
      return
    elseif event == "timer" and a == timer then
      tick()
      timer = os.startTimer(REFRESH_SECONDS)
    elseif event == "peripheral" or event == "peripheral_detach" then
      tick()
    elseif event == "monitor_resize" and a == monitorName then
      printError("Monitor size changed. Restart the controller to rebuild the layout.")
      return
    end
  end
end

local ok, err = pcall(main)

if not ok then
  pcall(setControlOutput, false)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  print("")
  printError("Solar controller stopped:")
  printError(tostring(err))
end
