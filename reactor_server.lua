--[[
  PWR Reactor Server v2.1
  Runs on the reactor computer (directly connected to HBMs NTM PWR reactor).
  
  Modules:
    lib/protocol.lua    - Network protocol
    lib/reactor_ctrl.lua - Reactor control logic (PID, safety, turbine speed)
  
  Hardware: Network card (modem) required.
  Optional: ElnProbe for turbine speed monitoring and motor/alarm control.
]]

package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"

local component = require("component")
local event     = require("event")
local computer  = require("computer")

local Protocol  = require("protocol")
local ReactorCtrl = require("reactor_ctrl")

-- ============================ INIT ============================

local reactor = ReactorCtrl.new()
reactor:init()

local modem = component.modem
if not modem then error("Network card (modem) required!") end
modem.open(Protocol.PORT)

reactor:log("INFO", "Modem port " .. Protocol.PORT .. " opened")
reactor:log("INFO", "Waiting for control room connection...")

-- ============================ CLIENT MANAGEMENT ============================

local clients = {}  -- [addr] = { lastSeen = uptime }

local function sendTo(addr, msgType, data)
  modem.send(addr, Protocol.PORT, Protocol.pack(msgType, data))
end

local function broadcastTelemetry()
  local telemetry = Protocol.buildTelemetry(reactor:getState(), reactor:getConfig(), reactor:getLog())
  local raw = Protocol.pack(Protocol.MSG.TELEMETRY, telemetry)
  for addr in pairs(clients) do
    pcall(modem.send, addr, Protocol.PORT, raw)
  end
end

local function handleCommand(addr, cmd)
  local S = reactor:getState()

  if cmd.type == Protocol.MSG.HELLO then
    clients[addr] = { lastSeen = computer.uptime() }
    reactor:log("INFO", "Client connected: " .. addr:sub(1, 8))
    sendTo(addr, Protocol.MSG.STATUS, { msg = "Connected to PWR Server v" .. reactor:getConfig().SYS.VERSION })
    return
  end

  if not clients[addr] then
    sendTo(addr, Protocol.MSG.STATUS, { msg = "ERROR: Send hello first" })
    return
  end
  clients[addr].lastSeen = computer.uptime()

  if cmd.type == Protocol.MSG.START then
    if S.mode == "IDLE" then
      reactor.S.startTimer = 0; reactor.S.heatTargetPct = 20
      reactor.S.heatTarget = reactor:pctToHeat(reactor.S.heatTargetPct)
      reactor.S.mode = "STARTUP"
      sendTo(addr, Protocol.MSG.STATUS, { msg = "Reactor starting..." })
    elseif S.mode == "SHUTDOWN" then
      reactor.S.mode = "POWER"
      sendTo(addr, Protocol.MSG.STATUS, { msg = "Resuming power..." })
    else
      sendTo(addr, Protocol.MSG.STATUS, { msg = "Cannot start: " .. S.mode })
    end

  elseif cmd.type == Protocol.MSG.STOP then
    if S.mode == "POWER" or S.mode == "STARTUP" then
      reactor.S.mode = "SHUTDOWN"
      sendTo(addr, Protocol.MSG.STATUS, { msg = "Shutting down..." })
    else
      sendTo(addr, Protocol.MSG.STATUS, { msg = "Cannot stop: " .. S.mode })
    end

  elseif cmd.type == Protocol.MSG.SCRAM then
    if not S.scramActive then
      reactor:scram("MANUAL SCRAM (control room)")
      sendTo(addr, Protocol.MSG.STATUS, { msg = "SCRAM ACTIVATED" })
    else
      sendTo(addr, Protocol.MSG.STATUS, { msg = "SCRAM already active" })
    end

  elseif cmd.type == Protocol.MSG.RESET then
    if S.mode == "SCRAM" then
      if S.coreHeat < S.thWarn * 0.4 then
        reactor.S.scramActive = false; reactor.S.scramReason = ""
        reactor.S.az1Active = false; reactor.S.az2Active = false
        reactor:sirenOff(); reactor:pidReset(); reactor.S.mode = "IDLE"
        sendTo(addr, Protocol.MSG.STATUS, { msg = "SCRAM reset. IDLE." })
      else
        sendTo(addr, Protocol.MSG.STATUS, { msg = "Reset impossible: heat too high" })
      end
    elseif S.mode == "FAULT" then
      reactor.S.initTimer = 0; reactor.S.mode = "INIT"
      sendTo(addr, Protocol.MSG.STATUS, { msg = "FAULT reset. Re-initializing..." })
    end

  elseif cmd.type == Protocol.MSG.SET_POWER then
    local val = clamp(tonumber(cmd.value) or 50, 0, 100)
    if S.mode == "POWER" then
      reactor.S.heatTargetPct = val
      sendTo(addr, Protocol.MSG.STATUS, { msg = string.format("Power setpoint: %.0f%%", val) })
    else
      sendTo(addr, Protocol.MSG.STATUS, { msg = "Can only set power in POWER mode" })
    end

  elseif cmd.type == Protocol.MSG.RECALIBRATE then
    reactor:startCalibration()
    sendTo(addr, Protocol.MSG.STATUS, { msg = "Calibration started..." })

  elseif cmd.type == Protocol.MSG.PING then
    sendTo(addr, Protocol.MSG.PONG, {})

  elseif cmd.type == Protocol.MSG.GET_LOG then
    sendTo(addr, Protocol.MSG.LOG_DATA, { entries = reactor:getLog() })

  else
    sendTo(addr, Protocol.MSG.STATUS, { msg = "Unknown: " .. tostring(cmd.type) })
  end
end

function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- ============================ LOCAL DISPLAY ============================

local function localDisplay()
  local term = require("term")
  if not term.isAvailable() then return end
  term.setCursor(1, 1); term.clear()
  local S = reactor:getState()
  local CFG = reactor:getConfig()
  io.write(string.format("PWR Server v%s | Mode: %s\n", CFG.SYS.VERSION, S.mode))
  io.write(string.format("Uptime: %s | Cycles: %d\n", reactor.fmtT(S.uptime), S.cycleCount))
  io.write(string.format("Core: %s TU (%.1f%%)\n", reactor.fmtN(S.coreHeat), reactor.pct(S.coreHeat, S.heatCap)))
  io.write(string.format("Rods: %.1f%% | Flux: %.1f\n", S.rodLogical, S.flux))
  io.write(string.format("Clients: %d | Port: %d\n", (function() local n=0; for _ in pairs(clients) do n=n+1 end; return n end)(), Protocol.PORT))
  io.write("[Q] Quit\n")
end

-- ============================ MAIN LOOP ============================

local running = true

while running do
  local now = computer.uptime()
  local dt = math.max(now - reactor.S.lastTime, 0.001)

  reactor:update(dt)
  broadcastTelemetry()
  localDisplay()

  -- Cleanup stale clients
  for addr, info in pairs(clients) do
    if computer.uptime() - info.lastSeen > 60 then
      clients[addr] = nil
      reactor:log("INFO", "Client timeout: " .. addr:sub(1, 8))
    end
  end

  local ev = table.pack(event.pull(reactor:getConfig().SYS.CYCLE))
  if ev[1] == "modem_message" then
    local from, port, _, data = ev[2], ev[3], ev[4], ev[5]
    if port == Protocol.PORT and from and data then
      local msg = Protocol.unpack(data)
      if msg then handleCommand(from, msg) end
    end
  elseif ev[1] == "key_down" then
    if string.char(ev[3] or 0):lower() == "q" then running = false end
  end
end

-- Safe shutdown
reactor:sendRodsNow(100)
reactor:sirenOff()
reactor:motorOff()
reactor:alarmOff()
modem.close(Protocol.PORT)
print("\nPWR Server stopped. Rods inserted.")
