local CONTROL_SIDE = "back"
local CONTROL_COLOR = colors.white
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
