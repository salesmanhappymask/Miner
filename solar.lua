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

local function findNetworkMonitor()
  if MONITOR_NAME then
    if peripheral.isPresent(MONITOR_NAME) and peripheral.getType(MONITOR_NAME) == "monitor" then
      return MONITOR_NAME, peripheral.wrap(MONITOR_NAME)
    end
    error("Configured monitor not found: " .. MONITOR_NAME)
  end

  local bestName = nil
  local bestMonitor = nil
  local bestArea = -1

  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local monitor = peripheral.wrap(name)
      if monitor and monitor.getSize then
        local width, height = monitor.getSize()
        local area = width * height
        if area > bestArea then
          bestName = name
          bestMonitor = monitor
          bestArea = area
        end
      end
    end
  end

  return bestName, bestMonitor
end

local MON_NAME, mon = findNetworkMonitor()
if not mon then
  error("No monitor found on the peripheral network")
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
