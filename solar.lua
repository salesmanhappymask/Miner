local CONTROL_SIDE = "back"
local SOLAR_PREFIX = "extrautils_generatorsolar"
local CELL_PREFIX = "cofh_thermalexpansion_energycell"
local SOLAR_CAPACITY = 500000
local CELL_CAPACITY = 50000000
local EMPTY_THRESHOLD = 100
local START_DELAY = 7
local REFRESH_SECONDS = 0.25
local MONITOR_NAME = nil

local SIDES = { "left", "right", "top", "bottom", "front", "back" }

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

local function startsWith(value, prefix)
  if type(value) ~= "string" then
    return false
  end
  return value == prefix or value:sub(1, #prefix + 1) == prefix .. "_"
end

local function suffixNumber(name)
  local n = tostring(name):match("_(%d+)$")
  return tonumber(n)
end

local function formatRF(n)
  n = tonumber(n) or 0
  if n >= 1000000000 then
    return string.format("%.2fG", n / 1000000000)
  elseif n >= 1000000 then
    return string.format("%.2fM", n / 1000000)
  elseif n >= 1000 then
    return string.format("%.1fk", n / 1000)
  end
  return tostring(round(n))
end

local function formatPercent(value, maximum)
  if not maximum or maximum <= 0 then
    return "0.0%"
  end
  return string.format("%.1f%%", clamp(value / maximum * 100, 0, 100))
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
  if ok and pType then
    return pType
  end

  for i = 1, #modems do
    local modem = modems[i].modem
    if modem and modem.getTypeRemote then
      local typeOk, remoteType = pcall(modem.getTypeRemote, name)
      if typeOk and remoteType then
        return remoteType
      end
    end
  end

  return nil
end

local function safeWrap(name)
  local ok, wrapped = pcall(peripheral.wrap, name)
  if ok then
    return wrapped
  end
  return nil
end

local function findMonitor(names, modems)
  if MONITOR_NAME then
    local pType = getPeripheralType(MONITOR_NAME, modems)
    if pType == "monitor" then
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
  if not ok then
    return nil
  end
  if type(value) == "number" then
    return value
  end
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
  if value == nil or value <= 0 then
    return fallback
  end
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

    if an and bn and an ~= bn then
      return an < bn
    elseif an and not bn then
      return true
    elseif bn and not an then
      return false
    end

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
    end
  end

  return total, capacity, readable
end

<<<<<<< HEAD
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
=======
local function getBundledOutput()
  local ok, value = pcall(redstone.getBundledOutput, CONTROL_SIDE)
  if ok and type(value) == "number" then
    return value
  end
  return 0
end

local function setControlOutput(enabled)
  local current = getBundledOutput()
  local nextValue

  if enabled then
    nextValue = colors.combine(current, CONTROL_COLOR)
  else
    nextValue = colors.subtract(current, CONTROL_COLOR)
  end

  if nextValue ~= current then
    local ok = pcall(redstone.setBundledOutput, CONTROL_SIDE, nextValue)
    return ok
  end

  return true
>>>>>>> b18faf7a558cca34f362f091de31f674e0f6086d
end

local function makeUI(mon)
  local cache = {}
  local w, h = mon.getSize()
  local isColor = mon.isColor and mon.isColor() or false

  local C_BG = colors.black
  local C_HEADER = isColor and colors.lightGray or colors.black
  local C_DIV = isColor and colors.gray or colors.black
  local C_INSET = colors.black
  local C_ACCENT = isColor and colors.cyan or colors.white
  local C_TEXT = colors.white
  local C_MUTED = isColor and colors.lightGray or colors.white
  local C_BRAND = isColor and colors.blue or colors.white
  local C_GOOD = isColor and colors.lime or colors.white
  local C_WARN = isColor and colors.yellow or colors.white
  local C_BAD = isColor and colors.red or colors.white
  local C_BAR_BG = isColor and colors.gray or colors.black
  local C_SOLAR = isColor and colors.yellow or colors.white
  local C_CELL = isColor and colors.cyan or colors.white

  local function setBg(color)
    mon.setBackgroundColor(isColor and color or colors.black)
  end

  local function setFg(color)
    mon.setTextColor(isColor and color or colors.white)
  end

  local function refreshSize()
    local nw, nh = mon.getSize()
    if nw ~= w or nh ~= h then
      w, h = nw, nh
      cache = {}
      setBg(C_BG)
      setFg(C_TEXT)
      mon.clear()
    end
  end

  local function field(key, x, y, width, value, fg, bg, align)
    if width <= 0 or x < 1 or y < 1 or x > w or y > h then
      return
    end

    if x + width - 1 > w then
      width = w - x + 1
    end

    local valueText = tostring(value or "")
    if #valueText > width then
      valueText = valueText:sub(1, width)
    end

    local output
    if align == "right" then
      output = string.rep(" ", width - #valueText) .. valueText
    elseif align == "center" then
      local left = math.floor((width - #valueText) / 2)
      output = string.rep(" ", left) .. valueText .. string.rep(" ", width - #valueText - left)
    else
      output = valueText .. string.rep(" ", width - #valueText)
    end

    local sig = output .. ":" .. tostring(fg) .. ":" .. tostring(bg)
    if cache[key] == sig then
      return
    end

    setBg(bg or C_BG)
    setFg(fg or C_TEXT)
    mon.setCursorPos(x, y)
    mon.write(output)
    cache[key] = sig
  end

  local function fill(key, x, y, width, bg)
    field(key, x, y, width, "", C_TEXT, bg)
  end

  local function bar(key, x, y, width, value, maximum, fg)
    if width <= 0 then
      return
    end

    local filled = 0
    if maximum and maximum > 0 then
      filled = round(width * clamp(value / maximum, 0, 1))
    end

    filled = clamp(filled, 0, width)
    fill(key .. "_all", x, y, width, C_BAR_BG)

    if filled > 0 then
      fill(key .. "_filled", x, y, filled, fg)
    end

    if filled < width then
      fill(key .. "_rest", x + filled, y, width - filled, C_BAR_BG)
    end
  end

  local function clear()
    setBg(C_BG)
    setFg(C_TEXT)
    mon.clear()
    cache = {}
  end

  return {
    C_BG = C_BG,
    C_HEADER = C_HEADER,
    C_DIV = C_DIV,
    C_INSET = C_INSET,
    C_ACCENT = C_ACCENT,
    C_TEXT = C_TEXT,
    C_MUTED = C_MUTED,
    C_BRAND = C_BRAND,
    C_GOOD = C_GOOD,
    C_WARN = C_WARN,
    C_BAD = C_BAD,
    C_SOLAR = C_SOLAR,
    C_CELL = C_CELL,
    width = function() return w end,
    height = function() return h end,
    refreshSize = refreshSize,
    field = field,
    fill = fill,
    bar = bar,
    clear = clear
  }
end

local function printStartup(modems, monitorName, solars, cells)
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
  print("Solar generators: " .. tostring(#solars))
  print("Energy cells: " .. tostring(#cells))
<<<<<<< HEAD
  print("Control: standard redstone on " .. CONTROL_SIDE)
  print("RedNet subnet: white, selected on cable face")
=======
  print("Control: " .. CONTROL_SIDE .. " / white")
>>>>>>> b18faf7a558cca34f362f091de31f674e0f6086d
  print("")
end

local function main()
  local modems = findWiredModems()
  local names = getAllPeripheralNames(modems)
  local monitorName, mon = findMonitor(names, modems)
  local solars, cells = discoverDevices(names, modems)

  printStartup(modems, monitorName, solars, cells)

  if #modems == 0 then
    printError("No wired modem with remote peripheral support was found.")
    print("The computer can still see directly attached peripherals, but not the remote monitor.")
    return
  end

  if not mon then
    printError("No monitor was found on the wired peripheral network.")
    print("Right-click the wired modem attached to the monitor so it receives a name such as monitor_12.")
    return
  end

  if mon.setTextScale then
    pcall(mon.setTextScale, 0.5)
  end

  local ui = makeUI(mon)
  ui.clear()

  local signalOn = false
  local signalStartedAt = nil
  local stateText = "CHARGING"
  local stateColor = ui.C_GOOD
  local lastNameSignature = ""

  local function namesSignature(list)
    return table.concat(list, "|")
  end

  local function refreshDiscovery()
    local newModems = findWiredModems()
    local newNames = getAllPeripheralNames(newModems)
    local newSig = namesSignature(newNames)

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

    local allReadable = true
    local anyFull = false
    local allEmpty = true

    for i = 1, #solars do
      local device = solars[i]

      if not device.readable then
        allReadable = false
      else
        if device.stored >= device.maximum then
          anyFull = true
        end

        if device.stored >= EMPTY_THRESHOLD then
          allEmpty = false
        end
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
<<<<<<< HEAD

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
        stateText = string.format("STARTING %.1fs", START_DELAY - elapsed)
        stateColor = ui.C_WARN
      else
        stateText = "TRANSFER ACTIVE"
        stateColor = ui.C_ACCENT
      end
    else
      stateText = "STORING POWER"
=======
      setControlOutput(true)
    elseif signalOn and allEmpty then
      signalOn = false
      signalStartedAt = nil
      setControlOutput(false)
    end

    if signalOn then
      local elapsed = os.clock() - signalStartedAt
      if elapsed < START_DELAY then
        stateText = string.format("ARMED %.1fs", START_DELAY - elapsed)
        stateColor = ui.C_WARN
      else
        stateText = "DISCHARGING"
        stateColor = ui.C_ACCENT
      end
    else
      stateText = "CHARGING"
>>>>>>> b18faf7a558cca34f362f091de31f674e0f6086d
      stateColor = ui.C_GOOD
    end
  end

  local function generatorStatus(device)
    if not device.readable then
      return "ERROR", ui.C_BAD
    end

    if signalOn then
      if device.stored < EMPTY_THRESHOLD then
        return "EMPTY", ui.C_MUTED
      end

      if os.clock() - signalStartedAt < START_DELAY then
<<<<<<< HEAD
        return "WAIT", ui.C_WARN
=======
        return "ARMED", ui.C_WARN
>>>>>>> b18faf7a558cca34f362f091de31f674e0f6086d
      end

      return "DRAIN", ui.C_ACCENT
    end

    if device.stored >= device.maximum then
      return "FULL", ui.C_WARN
    end

<<<<<<< HEAD
    return "STORE", ui.C_GOOD
=======
    return "CHARGE", ui.C_GOOD
>>>>>>> b18faf7a558cca34f362f091de31f674e0f6086d
  end

  local function box(prefix, x, y, width, height, title)
    if width < 6 or height < 4 then
      return
    end

    ui.fill(prefix .. "_top", x, y, width, ui.C_DIV)
    ui.fill(prefix .. "_bottom", x, y + height - 1, width, ui.C_DIV)

    for yy = y + 1, y + height - 2 do
      ui.fill(prefix .. "_left_" .. yy, x, yy, 1, ui.C_DIV)
      ui.fill(prefix .. "_right_" .. yy, x + width - 1, yy, 1, ui.C_DIV)
      ui.fill(prefix .. "_inside_" .. yy, x + 1, yy, width - 2, ui.C_INSET)
    end

    ui.fill(prefix .. "_sub", x + 1, y + 1, width - 2, ui.C_HEADER)
    ui.fill(prefix .. "_accent", x + 1, y + 1, 1, ui.C_ACCENT)
    ui.field(prefix .. "_title", x + 3, y + 1, width - 5, title, ui.C_BRAND, ui.C_HEADER)
  end

  local function draw(solarTotal, solarCapacity, solarReadable, cellTotal, cellCapacity, cellReadable)
    ui.refreshSize()

    local w = ui.width()
    local h = ui.height()
    local margin = 2
    local gap = 1
    local topY = 4
    local summaryH = 9
    local availableW = w - margin * 2 - gap
    local leftW = math.floor(availableW / 2)
    local rightW = availableW - leftW
    local leftX = margin
    local rightX = leftX + leftW + gap

    ui.fill("header", 1, 1, w, ui.C_HEADER)
    ui.fill("divider", 1, 2, w, ui.C_DIV)
    ui.field("title", 2, 1, math.max(1, w - 12), "Solar Reserve Controller", ui.C_TEXT, ui.C_HEADER)
    ui.field("brand", math.max(1, w - 7), 1, math.min(7, w), "ZelOS", ui.C_BRAND, ui.C_HEADER, "right")

    box("solar", leftX, topY, leftW, summaryH, "SOLAR RESERVE")
    box("cell", rightX, topY, rightW, summaryH, "RESONANT STORAGE")

    local sy = topY + 3
    ui.field("solar_online", leftX + 3, sy, leftW - 6, "Online " .. solarReadable .. "/" .. #solars, ui.C_MUTED, ui.C_INSET)
    ui.field("solar_rf", leftX + 3, sy + 1, leftW - 6, formatRF(solarTotal) .. " / " .. formatRF(solarCapacity) .. " RF", ui.C_TEXT, ui.C_INSET)
    ui.bar("solar_bar", leftX + 3, sy + 3, leftW - 6, solarTotal, solarCapacity, ui.C_SOLAR)
    ui.field("solar_pct", leftX + 3, sy + 4, leftW - 6, formatPercent(solarTotal, solarCapacity), ui.C_TEXT, ui.C_INSET, "right")

    local cy = topY + 3
    ui.field("cell_online", rightX + 3, cy, rightW - 6, "Online " .. cellReadable .. "/" .. #cells, ui.C_MUTED, ui.C_INSET)
    ui.field("cell_rf", rightX + 3, cy + 1, rightW - 6, formatRF(cellTotal) .. " / " .. formatRF(cellCapacity) .. " RF", ui.C_TEXT, ui.C_INSET)
    ui.bar("cell_bar", rightX + 3, cy + 3, rightW - 6, cellTotal, cellCapacity, ui.C_CELL)
    ui.field("cell_pct", rightX + 3, cy + 4, rightW - 6, formatPercent(cellTotal, cellCapacity), ui.C_TEXT, ui.C_INSET, "right")

    local controlY = topY + summaryH + 1
    ui.fill("control_top", margin, controlY, w - margin * 2, 2, ui.C_HEADER)
    ui.fill("control_accent", margin, controlY, 1, 2, ui.C_ACCENT)
<<<<<<< HEAD
    ui.field("control_label", margin + 2, controlY, 19, "TRANSFER CONTROL", ui.C_BRAND, ui.C_HEADER)
    ui.field("control_state", margin + 22, controlY, math.max(1, w - margin * 2 - 24), stateText, stateColor, ui.C_HEADER, "right")
    ui.field("control_signal", margin + 2, controlY + 1, 24, "RedNet white / rear", ui.C_MUTED, ui.C_HEADER)
    ui.field("control_signal_state", margin + 27, controlY + 1, math.max(1, w - margin * 2 - 29), signalOn and "SIGNAL ON" or "SIGNAL OFF", signalOn and ui.C_WARN or ui.C_MUTED, ui.C_HEADER, "right")
=======
    ui.field("control_label", margin + 2, controlY, 18, "WHITE / BACK", ui.C_MUTED, ui.C_HEADER)
    ui.field("control_state", margin + 21, controlY, math.max(1, w - margin * 2 - 23), stateText, stateColor, ui.C_HEADER, "right")
    ui.field("control_output", margin + 2, controlY + 1, w - margin * 2 - 3, signalOn and "Bundled output ON" or "Bundled output OFF", ui.C_TEXT, ui.C_HEADER)
>>>>>>> b18faf7a558cca34f362f091de31f674e0f6086d

    local listY = controlY + 3
    local bottomY = h - 1

    if listY <= bottomY then
      ui.fill("gen_header", margin, listY, w - margin * 2, 1, ui.C_HEADER)
      ui.fill("gen_accent", margin, listY, 1, 1, ui.C_ACCENT)
      ui.field("gen_title", margin + 2, listY, w - margin * 2 - 3, "SOLAR GENERATORS", ui.C_BRAND, ui.C_HEADER)

      local listHeight = bottomY - listY
      local columns = w >= 50 and 2 or 1
      local colGap = 1
      local usableW = w - margin * 2 - (columns - 1) * colGap
      local colW = math.floor(usableW / columns)
      local rowsPerCol = math.max(1, listHeight)
      local visible = rowsPerCol * columns

      for slot = 1, visible do
        local col = math.floor((slot - 1) / rowsPerCol)
        local row = (slot - 1) % rowsPerCol
        local x = margin + col * (colW + colGap)
        local y = listY + 1 + row
        local device = solars[slot]

        if device then
          local number = suffixNumber(device.name) or slot
          local status, statusColor = generatorStatus(device)
          local pct = device.readable and formatPercent(device.stored, device.maximum) or "--"
          local amount = device.readable and formatRF(device.stored) or "ERR"

          local stateW = 6
          local valueW = 8
          local pctW = 7
          local labelW = math.max(4, colW - stateW - valueW - pctW - 3)
          local pctX = x + labelW + 1
          local valueX = pctX + pctW + 1
          local stateX = valueX + valueW + 1

          ui.field("g_label_" .. slot, x, y, labelW, "G" .. number, ui.C_ACCENT, ui.C_INSET)
          ui.field("g_pct_" .. slot, pctX, y, pctW, pct, ui.C_TEXT, ui.C_INSET, "right")
          ui.field("g_val_" .. slot, valueX, y, valueW, amount, ui.C_MUTED, ui.C_INSET, "right")
          ui.field("g_state_" .. slot, stateX, y, stateW, status, statusColor, ui.C_INSET, "right")
        else
          ui.field("g_clear_" .. slot, x, y, colW, "", ui.C_TEXT, ui.C_INSET)
        end
      end
    end
  end

  local function tick()
    refreshDiscovery()

    local solarTotal, solarCapacity, solarReadable = sampleDevices(solars, SOLAR_CAPACITY)
    local cellTotal, cellCapacity, cellReadable = sampleDevices(cells, CELL_CAPACITY)

    updateControl()
    draw(solarTotal, solarCapacity, solarReadable, cellTotal, cellCapacity, cellReadable)
  end

  setControlOutput(false)
  lastNameSignature = namesSignature(names)
  tick()

  print("Running.")
  print("Monitor: " .. monitorName)
  print("Press Ctrl+T to stop safely.")

  local timer = os.startTimer(REFRESH_SECONDS)

  while true do
    local event, a = os.pullEventRaw()

    if event == "terminate" then
      setControlOutput(false)
      print("")
<<<<<<< HEAD
      print("Stopped. Rear redstone output disabled.")
=======
      print("Stopped. White output disabled.")
>>>>>>> b18faf7a558cca34f362f091de31f674e0f6086d
      return
    elseif event == "timer" and a == timer then
      tick()
      timer = os.startTimer(REFRESH_SECONDS)
    elseif event == "peripheral" or event == "peripheral_detach" then
      tick()
    elseif event == "monitor_resize" and a == monitorName then
      ui.clear()
      tick()
    end
  end
end

local ok, err = pcall(main)

if not ok then
  pcall(setControlOutput, false)
  print("")
  printError("Solar controller stopped:")
  printError(tostring(err))
end
