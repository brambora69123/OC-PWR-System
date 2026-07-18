local component = require("component")
local event = require("event")
local computer = require("computer")

local RS_SIDE = 2
local RS_SCRAM = 3
local TIMEOUT = 5.0
local PULSE_MIN = 0.05

local rs = component.redstone
local gpu = component.isAvailable("gpu") and component.gpu or nil
local W, H = 40, 10
if gpu then
  pcall(gpu.setResolution, W, H)
end

local function gw(x, y, s)
  if gpu then pcall(gpu.set, x, y, tostring(s)) end
end

local function gs(fg, bg)
  if gpu then
    if fg then pcall(gpu.setForeground, fg) end
    if bg then pcall(gpu.setBackground, bg) end
  end
end

local function cls()
  if gpu then pcall(gpu.fill, 1, 1, W, H, " ") end
end

local state = {
  lastPulse = computer.uptime(),
  lastVal = 0,
  triggered = false,
  resetNeeded = false,
  pulseCount = 0,
  scramCount = 0,
}

local function sendScram(active)
  if rs then pcall(rs.setOutput, RS_SCRAM, active and 15 or 0) end
end

local function draw()
  cls()
  gs(0x00D4FF, 0x000D1F)
  gw(1, 1, "  CASCAD WATCHDOG")
  gs(0x5A8AAB, 0x000D1F)
  gw(1, 2, string.format("  Pulses: %d", state.pulseCount))
  local dt = computer.uptime() - state.lastPulse
  local col = dt < 2 and 0x00FF80 or (dt < 4 and 0xFFCC00 or 0xFF1A1A)
  gs(col, 0x000D1F)
  gw(1, 3, string.format("  Last beat: %.1fs ago", dt))
  if state.triggered then
    gs(0xFFFFFF, 0x440000)
    gw(1, 5, "  !! TIMEOUT -- SCRAM !!  ")
    gs(0xFF1A1A, 0x000D1F)
    gw(1, 6, string.format("  SCRAM count: %d", state.scramCount))
    gs(0x5A8AAB, 0x000D1F)
    gw(1, 7, "  Press [R] to reset")
  else
    gs(0x00FF80, 0x000D1F)
    gw(1, 5, "  Heartbeat OK          ")
    gs(0x000D1F, 0x000D1F)
    gw(1, 6, "                        ")
    gw(1, 7, "                        ")
  end
  gs(0x334455, 0x000D1F)
  gw(1, H, "  [R] Reset  [Q] Quit   ")
end

sendScram(false)

while true do
  local ev = {event.pull(0.25, "key_down", "redstone_changed")}
  local now = computer.uptime()

  if ev[1] == "redstone_changed" then
    local val = rs and rs.getInput(RS_SIDE) or 0
    if val > 0 and state.lastVal == 0 then
      local gap = now - state.lastPulse
      if gap >= PULSE_MIN then
        state.lastPulse = now
        state.pulseCount = state.pulseCount + 1
        if state.triggered and not state.resetNeeded then
          state.triggered = false
          sendScram(false)
        end
      end
    end
    state.lastVal = val
  end

  if ev[1] == "key_down" then
    local char = ev[3]
    if char == string.byte("r") or char == string.byte("R") then
      if state.triggered then
        state.triggered = false
        state.resetNeeded = false
        sendScram(false)
      end
    elseif char == string.byte("q") or char == string.byte("Q") then
      sendScram(false)
      cls()
      break
    end
  end

  local dt = now - state.lastPulse
  if dt > TIMEOUT and not state.triggered then
    state.triggered = true
    state.scramCount = state.scramCount + 1
    sendScram(true)
  end

  draw()
end
