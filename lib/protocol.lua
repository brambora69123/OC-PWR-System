--[[
  lib/protocol.lua - Network Protocol Definitions
  Shared between reactor_server and control_client.
  Defines message types, serialization, and port configuration.
]]

local serial = require("serialization")

local Protocol = {}

Protocol.PORT = 7777
Protocol.VERSION = "2.1"
Protocol.SERIALIZE = serial.serialize
Protocol.UNSERIALIZE = serial.unserialize

-- Message types
Protocol.MSG = {
  -- Client -> Server
  HELLO       = "hello",
  START       = "start",
  STOP        = "stop",
  SCRAM       = "scram",
  RESET       = "reset",
  SET_POWER   = "setPower",
  RECALIBRATE = "recalibrate",
  PING        = "ping",
  GET_LOG     = "getLog",

  -- Server -> Client
  STATUS      = "status",
  TELEMETRY   = "telemetry",
  LOG_DATA    = "log",
  PONG        = "pong",
}

-- Build a message table
function Protocol.pack(msgType, data)
  local msg = { type = msgType }
  if data then
    for k, v in pairs(data) do
      msg[k] = v
    end
  end
  return Protocol.SERIALIZE(msg)
end

-- Unpack a received message
function Protocol.unpack(raw)
  local ok, msg = pcall(Protocol.UNSERIALIZE, raw)
  if ok and type(msg) == "table" then
    return msg
  end
  return nil
end

-- Build telemetry payload from reactor state
function Protocol.buildTelemetry(S, CFG, logEntries)
  local t = {
    type         = Protocol.MSG.TELEMETRY,
    uptime       = S.uptime,
    mode         = S.mode,
    coreHeat     = S.coreHeat,
    hullHeat     = S.hullHeat,
    heatCap      = S.heatCap,
    hullCap      = S.hullCap,
    flux         = S.flux,
    rodLogical   = S.rodLogical,
    rodTarget    = S.rodTarget,
    fuelAmt      = S.fuelAmt,
    fuelProg     = S.fuelProg,
    fuelMax      = S.fuelMax,
    coldFill     = S.coldFill,
    coldMax      = S.coldMax,
    hotFill      = S.hotFill,
    hotMax       = S.hotMax,
    radiation    = S.radiation,
    turbineSpeed = S.turbineSpeed,
    motorOn      = S.motorOn,
    alarmOn      = S.alarmOn,
    turbineFault = S.turbineFault,
    heatTargetPct = S.heatTargetPct or 0,
    heatTarget   = S.heatTarget,
    pidOut       = S.pidOut,
    pidIntegral  = S.pidIntegral,
    heatTrend    = S.heatTrend,
    thWarn       = S.thWarn,
    thAZ1        = S.thAZ1,
    thAZ2        = S.thAZ2,
    thScram      = S.thScram,
    az1Active    = S.az1Active,
    az2Active    = S.az2Active,
    scramActive  = S.scramActive,
    scramReason  = S.scramReason,
    scramCount   = S.scramCount,
    sirenOn      = S.sirenOn,

    cycleCount   = S.cycleCount,
    calibrated   = CFG.AUTO.CALIBRATED,
    cfg = {
      heatCap    = CFG.HEAT.CAP,
      pwrMin     = CFG.HEAT.PWR_MIN,
      pwrMax     = CFG.HEAT.PWR_MAX,
      lfEnabled  = CFG.LF.ENABLED,
      lfTarget   = CFG.LF.TARGET_SPEED,
      pidKP      = CFG.PID.KP,
      pidKI      = CFG.PID.KI,
      pidKD      = CFG.PID.KD,
      turbineMax = CFG.ELN.TURBINE_MAX,
      turbineOptLo = CFG.ELN.TURBINE_OPTIMAL_LO,
      turbineOptHi = CFG.ELN.TURBINE_OPTIMAL_HI,
    },
    log = {},
  }
  local startLog = math.max(1, #logEntries - 49)
  for i = startLog, #logEntries do
    table.insert(t.log, logEntries[i])
  end
  return t
end

return Protocol
