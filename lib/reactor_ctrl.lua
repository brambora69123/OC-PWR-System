--[[
  lib/reactor_ctrl.lua - Reactor Control Logic
  Encapsulates PID control, load following, safety interlocks,
  auto-calibration, and all reactor state management.
  
  Usage:
    local ReactorCtrl = require("reactor_ctrl")
    local reactor = ReactorCtrl.new()  -- or ReactorCtrl.new(customCFG)
    reactor.init()                     -- find components, load config
    reactor.readAll()                  -- poll reactor sensors
    reactor.update(dt)                 -- run one control cycle
    reactor.sendRods(level)            -- set rod insertion
    reactor.scram(reason)              -- emergency stop
    reactor.getState()                 -- get full state table
]]

local component = require("component")
local computer  = require("computer")

local ReactorCtrl = {}
ReactorCtrl.__index = ReactorCtrl

-- Default configuration
local function defaultConfig()
  return {
    AUTO = {
      CALIBRATED  = false,
      CAL_FILE    = "/home/pwr_cfg.lua",
      WARN_F      = 0.75,
      AZ1_F       = 0.85,
      AZ2_F       = 0.92,
      SCRAM_F     = 0.96,
      PWR_MIN_F   = 0.10,
      PWR_MAX_F   = 0.75,
    },
    HEAT = {
      CAP         = 10000000,
      WARN        = 7500000,
      AZ1         = 8500000,
      AZ2         = 9200000,
      SCRAM       = 9600000,
      PWR_MIN     = 1000000,
      PWR_MAX     = 6000000,
    },
    RODS = {
      IDLE        = 98,
      START       = 70,
      PWR_FLOOR   = 5,
    },
    LF = {
      ENABLED      = true,
      TARGET_SPEED = 200,
      DEADBAND     = 3,
      RAMP_RATE    = 0.4,
      KP           = 1.5,
      KI           = 0.01,
      KD           = 1.0,
      WINDUP       = 10,
    },
    PID = {
      KP          = 0.000005,
      KI          = 0.0000001,
      KD          = 0.00001,
      WINDUP      = 1000000,
      ROD_CLAMP   = 5.0,
      DT_MIN      = 0.005,
    },
    COOLANT = {
      COLD_WARN   = 15,
      COLD_SCRAM  = 5,
      HOT_WARN    = 82,
      HOT_REDUCE  = 95,
      HOT_SCRAM   = 99,
    },
    FUEL  = { WARN_PCT = 20, STOP_PCT = 90 },
    RAD   = { WARN = 100, SCRAM = 500 },
    ELN = {
      PROBE_SIDES = {
        TURBINE_SPEED = "ZN",
        MOTOR_RELAY   = "ZP",
        ALARM         = "YP",
      },
      TURBINE_MAX       = 250,
      TURBINE_OPTIMAL_LO = 195,
      TURBINE_OPTIMAL_HI = 205,
      TURBINE_FAULT_MIN   = 50,
      TURBINE_FAULT_TIME  = 30,
      MOTOR_START_DELAY   = 5,
    },
    SYS = {
      VERSION      = "2.1",
      CYCLE        = 0.20,
      LOG_MAX      = 400,
      AUDIO        = true,
      RS_SIREN     = true,
      RS_SIDE      = 2,
    },
  }
end

-- Default state
local function defaultState()
  return {
    mode        = "INIT",
    coreHeat    = 0,  hullHeat   = 0,
    heatCap     = 10000000,  hullCap = 10000000,
    flux        = 0,
    rodLogical  = 100,  rodTarget = 100,
    fuelAmt     = 0,  fuelProg = 0,  fuelMax = 1,
    coldFill    = 0,  coldMax  = 128000,
    hotFill     = 0,  hotMax   = 128000,
    radiation   = 0,
    turbineSpeed = 0,
    motorOn     = false,  motorStartTimer = 0,
    alarmOn     = false,
    turbineFault = false,
    turbineFaultTimer = 0,
    lfIntegral  = 0,  lfPrevErr = 0,
    heatTarget  = 1000000,
    pidIntegral = 0,  pidPrevErr = 0,  pidOut = 0,
    heatHist    = {},  heatTrend = 0,
    thWarn      = 7500000,  thAZ1  = 8500000,
    thAZ2       = 9200000,  thScram= 9600000,
    az1Active   = false,  az2Active = false,
    scramActive = false,  scramReason = "",
    uptime      = 0,  scramCount = 0,
    cycleCount  = 0,  lastTime   = computer.uptime(),
    sirenOn     = false,

    startTimer  = 0,  initTimer  = 0,
    calRodsLock = false,
    calStep     = 0,  calTimer = 0,
    calData     = {},  calStatus = "",
    log         = {},  logHash = "",  logDupCnt = 0,
  }
end

-- ======================== UTILITY ========================

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function pct(v, m) if (m or 0) <= 0 then return 0 end; return clamp(v / m * 100, 0, 100) end
local function lerp(a, b, t) return a + (b - a) * clamp(t, 0, 1) end
local function safe(fn, ...) local ok, r = pcall(fn, ...); return ok and r or nil end

local function fmtN(n)
  n = math.floor(n or 0)
  local s = tostring(math.abs(n)); local r, l = "", #s
  for i = 1, l do r = r .. s:sub(i, i); if (l - i) % 3 == 0 and i < l then r = r .. "," end end
  return (n < 0 and "-" or "") .. r
end

local function fmtT(sec)
  sec = math.floor(sec)
  local h = math.floor(sec / 3600); local m = math.floor((sec % 3600) / 60); local s = sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

local function tSym(t)
  if t > 50000 then return "^^" elseif t > 10000 then return "^"
  elseif t < -50000 then return "vv" elseif t < -10000 then return "v"
  else return "-" end
end

-- ======================== CONSTRUCTOR ========================

function ReactorCtrl.new(customCFG)
  local self = setmetatable({}, ReactorCtrl)
  self.CFG = customCFG or defaultConfig()
  self.S = defaultState()
  self.C = {}   -- components
  self.modem = nil
  return self
end

-- ======================== COMPONENT INIT ========================

local function findComp(name, req)
  if component.isAvailable(name) then
    local a = component.list(name)()
    if a then return component.proxy(a) end
  end
  if req then error("Component not found: " .. name) end
  return nil
end

function ReactorCtrl: initComponents()
  self.C.pwr    = findComp("ntm_pwr_control", true)
  self.C.eln    = findComp("ElnProbe", false)
  self.C.geiger = findComp("ntm_geiger", false)
  self.C.rs     = findComp("redstone", false)
end

-- ======================== LOGGING ========================

local LVL = { INFO = "INF", WARN = "WRN", ERROR = "ERR", CRIT = "!!!" }

function ReactorCtrl:log(lv, msg)
  local hash = lv .. msg
  if hash == self.S.logHash then self.S.logDupCnt = self.S.logDupCnt + 1; return end
  if self.S.logDupCnt > 0 then
    local e = self.S.log[#self.S.log]
    if e then e.msg = e.msg .. string.format(" [x%d]", self.S.logDupCnt + 1) end
    self.S.logDupCnt = 0
  end
  self.S.logHash = hash
  local e = { t = fmtT(self.S.uptime), lvl = LVL[lv] or "INF", msg = msg }
  table.insert(self.S.log, e)
  while #self.S.log > self.CFG.SYS.LOG_MAX do table.remove(self.S.log, 1) end
  io.write(string.format("[%s][%s] %s\n", e.t, e.lvl, e.msg))
end

-- ======================== CONFIG PERSISTENCE ========================

function ReactorCtrl:saveCfg()
  local f = io.open(self.CFG.AUTO.CAL_FILE, "w")
  if not f then self:log("WARN", "Failed to save config"); return end
  local C = self.CFG
  f:write("-- PWR auto-config v" .. C.SYS.VERSION .. "\n\n")
  f:write("return {\n")
  f:write(string.format("  CALIBRATED = true,\n"))
  f:write(string.format("  HEAT_CAP   = %d,\n",  C.HEAT.CAP))
  f:write(string.format("  HEAT_WARN  = %d,\n",  C.HEAT.WARN))
  f:write(string.format("  HEAT_AZ1   = %d,\n",  C.HEAT.AZ1))
  f:write(string.format("  HEAT_AZ2   = %d,\n",  C.HEAT.AZ2))
  f:write(string.format("  HEAT_SCRAM = %d,\n",  C.HEAT.SCRAM))
  f:write(string.format("  PWR_MIN    = %d,\n",  C.HEAT.PWR_MIN))
  f:write(string.format("  PWR_MAX    = %d,\n",  C.HEAT.PWR_MAX))
  f:write(string.format("  PID_KP     = %.9f,\n", C.PID.KP))
  f:write(string.format("  PID_KI     = %.9f,\n", C.PID.KI))
  f:write(string.format("  PID_KD     = %.9f,\n", C.PID.KD))
  f:write(string.format("  LF_TARGET  = %d,\n",  C.LF.TARGET_SPEED))
  f:write(string.format("  LF_RAMP    = %.2f,\n", C.LF.RAMP_RATE))
  f:write("}\n")
  f:close()
  self:log("INFO", "Config saved")
end

function ReactorCtrl:loadCfg()
  local f = io.open(self.CFG.AUTO.CAL_FILE, "r")
  if not f then return false end
  f:close()
  local ok, data = pcall(dofile, self.CFG.AUTO.CAL_FILE)
  if not ok or type(data) ~= "table" or not data.CALIBRATED then return false end
  local C = self.CFG
  C.AUTO.CALIBRATED = true
  C.HEAT.CAP     = data.HEAT_CAP   or C.HEAT.CAP
  C.HEAT.WARN    = data.HEAT_WARN  or C.HEAT.WARN
  C.HEAT.AZ1     = data.HEAT_AZ1   or C.HEAT.AZ1
  C.HEAT.AZ2     = data.HEAT_AZ2   or C.HEAT.AZ2
  C.HEAT.SCRAM   = data.HEAT_SCRAM or C.HEAT.SCRAM
  C.HEAT.PWR_MIN = data.PWR_MIN    or C.HEAT.PWR_MIN
  C.HEAT.PWR_MAX = data.PWR_MAX    or C.HEAT.PWR_MAX
  C.PID.KP       = data.PID_KP     or C.PID.KP
  C.PID.KI       = data.PID_KI     or C.PID.KI
  C.PID.KD       = data.PID_KD     or C.PID.KD
  C.LF.TARGET_SPEED = data.LF_TARGET or C.LF.TARGET_SPEED
  C.LF.RAMP_RATE    = data.LF_RAMP   or C.LF.RAMP_RATE
  self:log("INFO", "Config loaded")
  return true
end

-- ======================== CALIBRATION ========================

function ReactorCtrl:startCalibration()
  self.S.mode     = "CALIBRATE"
  self.S.calStep  = 0
  self.S.calTimer = 0
  self.S.calData  = {}
  self.S.calStatus = "Initializing..."
  self:log("INFO", "=== AUTO-CALIBRATION START ===")
  if self.C.pwr then pcall(self.C.pwr.setLevel, 100) end
  self.S.rodTarget = 100
end

function ReactorCtrl:stepCalibrate(dt)
  local S, C, CFG = self.S, self.C, self.CFG
  S.calTimer = S.calTimer + dt
  local CAL_STEPS = 5

  if S.calStep == 0 then
    S.calStatus = string.format("Step 1/%d: Waiting for API... (%.1f/3.0)", CAL_STEPS, S.calTimer)
    if S.calTimer >= 3.0 then
      if type(S.coreHeat) ~= "number" or (S.coreHeat == 0 and S.fuelAmt == 0) then
        self:log("ERROR", "Calibration: no data -> FAULT")
        S.mode = "FAULT"; return
      end
      S.calData.heatAtStart = S.coreHeat
      S.calStep = 1; S.calTimer = 0
      self:log("INFO", string.format("Step 1 OK. heat=%s TU", fmtN(S.coreHeat)))
    end
    return
  end

  if S.calStep == 1 then
    S.calStatus = string.format("Step 2/%d: Reading heat capacity...", CAL_STEPS)
    if S.heatCap > 0 then
      S.calData.heatCap = S.heatCap; S.calStep = 2; S.calTimer = 0
    elseif S.calTimer >= 5.0 then
      S.calData.heatCap = CFG.HEAT.CAP; S.calStep = 2; S.calTimer = 0
      self:log("WARN", "heatCap not received, using default")
    end
    return
  end

  if S.calStep == 2 then
    S.calStatus = string.format("Step 3/%d: Measuring storage...", CAL_STEPS)
    if S.calTimer >= 2.0 then
      S.calData.energyMax = S.energyFill >= 0 and S.energyMax or 0
      S.calStep = 3; S.calTimer = 0
    end
    return
  end

  if S.calStep == 3 then
    local safeTemp = (S.calData.heatCap or CFG.HEAT.CAP) * 0.3
    if S.coreHeat > safeTemp then
      S.calData.heatRiseRate = 0; S.calStep = 4; S.calTimer = 0
      return
    end
    if S.calTimer < 0.5 then
      S.calRodsLock = true
      if C.pwr then pcall(C.pwr.setLevel, 10) end
      S.calData.heatSamples = {}
    elseif S.calTimer < 5.5 then
      table.insert(S.calData.heatSamples, S.coreHeat)
    else
      S.calRodsLock = false
      if C.pwr then pcall(C.pwr.setLevel, 100) end
      local samples = S.calData.heatSamples or {}
      if #samples >= 2 then
        local span = (#samples - 1) * CFG.SYS.CYCLE
        S.calData.heatRiseRate = (samples[#samples] - samples[1]) / math.max(span, 0.1)
      else
        S.calData.heatRiseRate = 0
      end
      S.calStep = 4; S.calTimer = 0
    end
    return
  end

  if S.calStep == 4 then
    S.calStatus = string.format("Step 5/%d: Applying results...", CAL_STEPS)
    if S.calTimer >= 1.0 then
      self:calApplyResults()
      self:saveCfg()
      S.calStep = 5; S.calTimer = 0
      self:log("INFO", "=== CALIBRATION COMPLETE ===")
    end
    return
  end

  if S.calStep == 5 then
    if C.pwr then pcall(C.pwr.setLevel, 100) end
    S.rodTarget = 100
    if S.calTimer >= 3.0 then S.mode = "IDLE" end
    return
  end
end

function ReactorCtrl:calApplyResults()
  local d, C, CFG = self.S.calData, self.C, self.CFG
  local cap = d.heatCap or CFG.HEAT.CAP
  CFG.HEAT.CAP     = cap
  CFG.HEAT.WARN    = math.floor(cap * CFG.AUTO.WARN_F)
  CFG.HEAT.AZ1     = math.floor(cap * CFG.AUTO.AZ1_F)
  CFG.HEAT.AZ2     = math.floor(cap * CFG.AUTO.AZ2_F)
  CFG.HEAT.SCRAM   = math.floor(cap * CFG.AUTO.SCRAM_F)
  CFG.HEAT.PWR_MIN = math.floor(cap * CFG.AUTO.PWR_MIN_F)
  CFG.HEAT.PWR_MAX = math.floor(cap * CFG.AUTO.PWR_MAX_F)

  local dT = d.heatRiseRate or 0
  if dT > 100 then
    local scale = math.max(dT, 1000)
    CFG.PID.KP = clamp(1.5 / scale, 0.0000005, 0.000005)
    CFG.PID.KI = CFG.PID.KP * 0.03
    CFG.PID.KD = CFG.PID.KP * 3.0
  end
  CFG.AUTO.CALIBRATED = true
end

-- ======================== SENSORS ========================

function ReactorCtrl:readAll()
  local S, C, CFG = self.S, self.C, self.CFG
  if not C.pwr then return false end

  local hOk, h1, h2, h3, h4 = pcall(C.pwr.getHeat)
  if not hOk then return false end
  if type(h1) == "table" then
    S.coreHeat = tonumber(h1.coreHeat or h1[1]) or 0
    S.hullHeat = tonumber(h1.hullHeat or h1[2]) or 0
    S.heatCap  = math.max(tonumber(h1.coreHeatCapacity or h1[3]) or self.CFG.HEAT.CAP, 1)
    S.hullCap  = math.max(tonumber(h1.hullHeatCapacity or h1[4]) or self.CFG.HEAT.CAP, 1)
  elseif tonumber(h1) then
    S.coreHeat = tonumber(h1) or 0; S.hullHeat = tonumber(h2) or 0
    S.heatCap  = math.max(tonumber(h3) or self.CFG.HEAT.CAP, 1)
    S.hullCap  = math.max(tonumber(h4) or self.CFG.HEAT.CAP, 1)
  else
    return false
  end

  table.insert(S.heatHist, S.coreHeat)
  if #S.heatHist > 10 then table.remove(S.heatHist, 1) end
  if #S.heatHist >= 2 then
    local span = (#S.heatHist - 1) * self.CFG.SYS.CYCLE
    S.heatTrend = (S.heatHist[#S.heatHist] - S.heatHist[1]) / math.max(span, 0.001)
  end

  local f = safe(C.pwr.getFlux)
  S.flux = type(f) == "table" and (tonumber(f[1]) or 0) or (tonumber(f) or 0)

  local lOk, l1, l2 = pcall(C.pwr.getLevel)
  if lOk then
    if type(l1) == "table" then
      S.rodTarget  = tonumber(l1[1] or l1.rodTarget) or 100
      S.rodLogical = tonumber(l1[2] or l1.rodLevel)  or 100
    elseif tonumber(l1) then
      S.rodTarget = tonumber(l1) or 100; S.rodLogical = tonumber(l2) or S.rodTarget
    end
  end

  local fi = safe(C.pwr.getFuelInfo)
  if type(fi) == "table" then
    S.fuelAmt  = tonumber(fi.amountLoaded or fi[1]) or 0
    S.fuelProg = tonumber(fi.progress     or fi[2]) or 0
    S.fuelMax  = math.max(tonumber(fi.processTime or fi[3]) or 1, 1)
  elseif type(fi) == "number" then
    S.fuelAmt = fi
  end

  local ci = safe(C.pwr.getCoolantInfo)
  if type(ci) == "table" then
    S.coldFill = ci[1] or 0; S.coldMax = math.max(ci[2] or 128000, 1)
    S.hotFill  = ci[3] or 0; S.hotMax  = math.max(ci[4] or 128000, 1)
  end

  if C.geiger then S.radiation = tonumber(safe(C.geiger.getRads)) or 0 end

  if C.eln then
    local side = CFG.ELN.PROBE_SIDES.TURBINE_SPEED
    local ok, val = pcall(C.eln.signalGetIn, side)
    if ok and type(val) == "number" then
      S.turbineSpeed = val * CFG.ELN.TURBINE_MAX
    end
  end

  return true
end

-- ======================== CONTROL LOGIC ========================

function ReactorCtrl:calcThresholds()
  local S, C, CFG = self.S, self.C, self.CFG
  local cap = (S.heatCap and S.heatCap > 0) and S.heatCap or CFG.HEAT.CAP
  CFG.HEAT.CAP    = cap
  CFG.HEAT.WARN   = math.floor(cap * CFG.AUTO.WARN_F)
  CFG.HEAT.AZ1    = math.floor(cap * CFG.AUTO.AZ1_F)
  CFG.HEAT.AZ2    = math.floor(cap * CFG.AUTO.AZ2_F)
  CFG.HEAT.SCRAM  = math.floor(cap * CFG.AUTO.SCRAM_F)
  if not CFG.AUTO.CALIBRATED then
    CFG.HEAT.PWR_MIN = math.floor(cap * CFG.AUTO.PWR_MIN_F)
    CFG.HEAT.PWR_MAX = math.floor(cap * CFG.AUTO.PWR_MAX_F)
  end
  S.thWarn  = CFG.HEAT.WARN;  S.thAZ1 = CFG.HEAT.AZ1
  S.thAZ2   = CFG.HEAT.AZ2;   S.thScram = CFG.HEAT.SCRAM
end

function ReactorCtrl:sendRods(logical)
  local S, C, CFG = self.S, self.C, self.CFG
  if not C.pwr or S.calRodsLock then return end
  logical = clamp(math.floor(logical * 10 + 0.5) / 10, CFG.RODS.PWR_FLOOR, 100)
  if math.abs(logical - S.rodTarget) > 0.09 then
    if pcall(C.pwr.setLevel, logical) then S.rodTarget = logical end
  end
end

function ReactorCtrl:sendRodsNow(logical)
  local S, C = self.S, self.C
  if not C.pwr then return end
  pcall(C.pwr.setLevel, clamp(logical, 0, 100)); S.rodTarget = logical
end

function ReactorCtrl:pidReset()
  self.S.pidIntegral = 0
  self.S.pidPrevErr  = self.S.heatTarget - self.S.coreHeat
  self.S.pidOut      = 0
end

function ReactorCtrl:pidStep(dt)
  local S, CFG = self.S, self.CFG
  local eff = math.max(dt, CFG.PID.DT_MIN)
  local err = S.heatTarget - S.coreHeat
  S.pidIntegral = clamp(S.pidIntegral + err * eff, -CFG.PID.WINDUP, CFG.PID.WINDUP)
  local derr = (err - S.pidPrevErr) / eff; S.pidPrevErr = err
  S.pidOut = clamp(CFG.PID.KP * err + CFG.PID.KI * S.pidIntegral + CFG.PID.KD * derr,
                   -CFG.PID.ROD_CLAMP, CFG.PID.ROD_CLAMP)
  return S.pidOut
end

function ReactorCtrl:updateLF(dt)
  local S, CFG = self.S, self.CFG
  if not CFG.LF.ENABLED then return end
  local target = CFG.LF.TARGET_SPEED
  local err = target - S.turbineSpeed
  local activeErr = math.abs(err) > CFG.LF.DEADBAND and err or 0
  local speedDelta = S.turbineSpeed - (S.lfPrevSpeed or S.turbineSpeed)
  S.lfPrevSpeed = S.turbineSpeed
  S.lfIntegral = clamp(S.lfIntegral + activeErr * dt, -CFG.LF.WINDUP, CFG.LF.WINDUP)
  local demand = CFG.LF.KP * activeErr + CFG.LF.KI * S.lfIntegral + CFG.LF.KD * speedDelta / dt
  local maxStep = CFG.LF.RAMP_RATE * dt
  local newPct = clamp(S.heatTargetPct + demand * dt, 0, 100)
  newPct = clamp(newPct, S.heatTargetPct - maxStep, S.heatTargetPct + maxStep)
  S.heatTargetPct = clamp(newPct, 0, 100)
end

function ReactorCtrl:pctToHeat(p)
  return lerp(self.CFG.HEAT.PWR_MIN, self.CFG.HEAT.PWR_MAX, p / 100)
end

-- ======================== PROTECTIONS ========================

function ReactorCtrl:scram(reason)
  local S = self.S
  if S.scramActive then return end
  S.scramActive = true; S.scramReason = reason
  S.scramCount = S.scramCount + 1; S.mode = "SCRAM"
  self:sendRodsNow(100); self:pidReset(); self:sirenOn(); self:alarmOn()
  self:log("CRIT", "=== SCRAM #" .. S.scramCount .. " === Reason: " .. reason)
end

function ReactorCtrl:sirenOn()
  local S, C, CFG = self.S, self.C, self.CFG
  if S.sirenOn then return end; S.sirenOn = true
  if CFG.SYS.AUDIO then for _ = 1, 3 do pcall(computer.beep, 960, 0.12); pcall(computer.beep, 480, 0.08) end end
  if CFG.SYS.RS_SIREN and C.rs then pcall(C.rs.setOutput, CFG.SYS.RS_SIDE, 15) end
end

function ReactorCtrl:sirenOff()
  local S, C, CFG = self.S, self.C, self.CFG
  if not S.sirenOn then return end; S.sirenOn = false
  if CFG.SYS.RS_SIREN and C.rs then pcall(C.rs.setOutput, CFG.SYS.RS_SIDE, 0) end
end

function ReactorCtrl:motorOn()
  local S, C, CFG = self.S, self.C, self.CFG
  if S.motorOn then return end; S.motorOn = true
  if C.eln then
    pcall(C.eln.signalSetDir, CFG.ELN.PROBE_SIDES.MOTOR_RELAY, "out")
    pcall(C.eln.signalSetOut, CFG.ELN.PROBE_SIDES.MOTOR_RELAY, 1)
  end
  self:log("INFO", "=== RADIAL MOTOR STARTED ===")
end

function ReactorCtrl:motorOff()
  local S, C, CFG = self.S, self.C, self.CFG
  if not S.motorOn then return end; S.motorOn = false
  if C.eln then
    pcall(C.eln.signalSetDir, CFG.ELN.PROBE_SIDES.MOTOR_RELAY, "out")
    pcall(C.eln.signalSetOut, CFG.ELN.PROBE_SIDES.MOTOR_RELAY, 0)
  end
  self:log("INFO", "Radial motor stopped")
end

function ReactorCtrl:alarmOn()
  local S, C, CFG = self.S, self.C, self.CFG
  if S.alarmOn then return end; S.alarmOn = true
  if C.eln then
    pcall(C.eln.signalSetDir, CFG.ELN.PROBE_SIDES.ALARM, "out")
    pcall(C.eln.signalSetOut, CFG.ELN.PROBE_SIDES.ALARM, 1)
  end
end

function ReactorCtrl:alarmOff()
  local S, C, CFG = self.S, self.C, self.CFG
  if not S.alarmOn then return end; S.alarmOn = false
  if C.eln then
    pcall(C.eln.signalSetDir, CFG.ELN.PROBE_SIDES.ALARM, "out")
    pcall(C.eln.signalSetOut, CFG.ELN.PROBE_SIDES.ALARM, 0)
  end
end

function ReactorCtrl:checkTurbine(dt)
  local S, C, CFG = self.S, self.C, self.CFG
  if not C.eln then return end
  if S.motorOn then
    S.motorStartTimer = S.motorStartTimer + dt
    if S.motorStartTimer >= CFG.ELN.MOTOR_START_DELAY then
      if S.turbineSpeed < CFG.ELN.TURBINE_FAULT_MIN then
        if not S.turbineFault then
          S.turbineFault = true
          S.turbineFaultTimer = 0
          self:log("ERROR", "TURBINE FAULT: failed to speed up")
        end
      end
    end
  end
  if S.turbineFault then
    S.turbineFaultTimer = S.turbineFaultTimer + dt
    if S.turbineFaultTimer > 10 then
      S.turbineFault = false
      S.turbineFaultTimer = 0
    end
  end
end

function ReactorCtrl:checkProtections()
  local S, CFG = self.S, self.CFG
  if type(S.coreHeat) ~= "number" then self:scram("TELEMETRY LOSS"); return end
  if S.coreHeat >= S.thScram then
    self:scram(string.format("CORE OVERHEAT: %s TU", fmtN(S.coreHeat))); return end
  if S.hullHeat > 0 and S.hullHeat >= S.hullCap * 0.95 then
    self:scram(string.format("HULL OVERHEAT: %s TU", fmtN(S.hullHeat))); return end

  local cp = pct(S.coldFill, S.coldMax)
  if cp < CFG.COOLANT.COLD_SCRAM then
    self:scram(string.format("COOLANT LOSS: %.1f%%", cp)); return end
  local hp = pct(S.hotFill, S.hotMax)
  if hp >= CFG.COOLANT.HOT_SCRAM then
    self:scram(string.format("HOT TANK: %.1f%%", hp)); return end
  if S.radiation >= CFG.RAD.SCRAM then
    self:scram(string.format("RADIATION: %.0f rad/t", S.radiation)); return end

  if S.coreHeat >= S.thAZ2 then
    if not S.az2Active then
      S.az2Active = true
      self:log("ERROR", string.format("SCRAM-2: %s TU", fmtN(S.coreHeat)))
      self:sendRodsNow(100); self:pidReset()
      if S.mode == "POWER" then S.mode = "SHUTDOWN" end
    end; return
  else if S.az2Active then S.az2Active = false end end

  if S.coreHeat >= S.thAZ1 then
    if not S.az1Active then S.az1Active = true end
    S.lfPowerPct = math.max(S.lfPowerPct - 15, 0)
    self:sendRods(math.min(S.rodTarget + 10, 100)); return
  else if S.az1Active then S.az1Active = false end end

  if S.coreHeat >= S.thWarn then
    local b = math.floor(S.coreHeat / 200000)
    local pb = math.floor((S.coreHeat - S.heatTrend * CFG.SYS.CYCLE) / 200000)
    if b ~= pb then self:log("WARN", string.format("High heat: %s TU", fmtN(S.coreHeat))) end
  end

  if S.fuelAmt > 0 and S.fuelMax > 0 then
    if pct(S.fuelProg, S.fuelMax) >= CFG.FUEL.STOP_PCT and S.mode == "POWER" then
      self:log("WARN", "Fuel depleted -> shutdown"); S.mode = "SHUTDOWN"
    end
  elseif S.fuelAmt <= 0 and S.mode == "POWER" then
    self:log("ERROR", "No fuel -> shutdown"); S.mode = "SHUTDOWN"
  end
end

-- ======================== MODE HANDLERS ========================

function ReactorCtrl:modeInit()
  local S, CFG = self.S, self.CFG
  self:sendRodsNow(100)
  self:motorOff()
  self:alarmOff()
  if S.fuelAmt == 0 and S.coreHeat == 0 then
    S.initTimer = S.initTimer + CFG.SYS.CYCLE
    if S.initTimer < 3.0 then return end
  end
  S.initTimer = 0
  if S.coreHeat > 0 and S.coreHeat >= S.thAZ1 then
    self:log("ERROR", "Heat too high -> FAULT"); S.mode = "FAULT"; return
  end
  if not CFG.AUTO.CALIBRATED then
    self:log("INFO", "No config -> calibration"); self:startCalibration(); return
  end
  S.heatTargetPct = 0
  S.heatTarget = self:pctToHeat(0)
  self:log("INFO", string.format("OK. Fuel:%d Heat:%s TU", S.fuelAmt, fmtN(S.coreHeat)))
  S.mode = "IDLE"
end

function ReactorCtrl:modeIdle() self:sendRods(self.CFG.RODS.IDLE); self:pidReset(); self.S.lfIntegral = 0 end

function ReactorCtrl:modeStartup(dt)
  local S, CFG = self.S, self.CFG
  if not S.motorOn then
    self:motorOn()
    S.motorStartTimer = 0
    S.startTimer = 0
  end
  if S.turbineSpeed < CFG.ELN.TURBINE_FAULT_MIN and S.motorStartTimer >= CFG.ELN.MOTOR_START_DELAY then
    if not S.turbineFault then
      self:log("WARN", "Waiting for turbine speedup...")
    end
    return
  end
  S.startTimer = S.startTimer + dt
  if S.rodTarget <= CFG.RODS.START then
    self:log("INFO", string.format("Startup done. Rods %.1f%% -> POWER", S.rodTarget))
    self:pidReset(); S.mode = "POWER"; return
  end
  local rate = S.coreHeat > S.heatTarget * 0.6 and 0.5 or 2.0
  self:sendRods(math.max(S.rodTarget - rate * dt, CFG.RODS.START))
end

function ReactorCtrl:modePower(dt)
  self:updateLF(dt)
  self.S.heatTarget = self:pctToHeat(self.S.heatTargetPct)
  self:calcThresholds()
  local delta = self:pidStep(dt)
  self:sendRods(clamp(self.S.rodTarget - delta, self.CFG.RODS.PWR_FLOOR, 100))
end

function ReactorCtrl:modeShutdown(dt)
  self:sendRods(math.min(self.S.rodTarget + 5 * dt, 100)); self:pidReset()
  if self.S.rodTarget >= 99.5 then
    self:motorOff()
    self:alarmOff()
    self:log("INFO", string.format("Shutdown done. Heat: %s TU", fmtN(self.S.coreHeat)))
    self.S.mode = "IDLE"
  end
end

function ReactorCtrl:modeScram() self:sendRodsNow(100); self:motorOff() end
function ReactorCtrl:modeFault() self:sendRodsNow(100); self:motorOff() end

-- ======================== MAIN UPDATE ========================

function ReactorCtrl:update(dt)
  local S = self.S
  S.lastTime = computer.uptime(); S.uptime = S.uptime + dt; S.cycleCount = S.cycleCount + 1

  local rOk = self:readAll()
  if not rOk and S.mode ~= "INIT" and S.mode ~= "FAULT" and S.mode ~= "CALIBRATE" then
    self:scram("CONNECTION LOSS")
  end

  self:calcThresholds()

  if S.mode == "CALIBRATE" then
    local ok, err = pcall(self.stepCalibrate, self, dt)
    if not ok then self:log("ERROR", "Cal error: " .. tostring(err)); S.mode = "FAULT" end
  else
    if S.mode ~= "INIT" and S.mode ~= "FAULT" and S.mode ~= "SCRAM" then
      local ok, err = pcall(self.checkProtections, self)
      if not ok then self:log("ERROR", "Prot error: " .. tostring(err)); self:scram("PROTECTION ERROR") end
      local tOk, tErr = pcall(self.checkTurbine, self, dt)
      if not tOk then self:log("ERROR", "Turbine check error: " .. tostring(tErr)) end
    end
    pcall(function()
      if     S.mode == "INIT"     then self:modeInit()
      elseif S.mode == "IDLE"     then self:modeIdle()
      elseif S.mode == "STARTUP"  then self:modeStartup(dt)
      elseif S.mode == "POWER"    then self:modePower(dt)
      elseif S.mode == "SHUTDOWN" then self:modeShutdown(dt)
      elseif S.mode == "SCRAM"    then self:modeScram()
      elseif S.mode == "FAULT"    then self:modeFault()
      end
    end)
  end
end

-- ======================== INIT ========================

function ReactorCtrl:init()
  self:components()
  self:calcThresholds()
  if self:loadCfg() then
    self:calcThresholds()
  end
  self.S.heatTargetPct = 0
  self.S.heatTarget = self:pctToHeat(0)
  self:log("INFO", "=== PWR Control v" .. self.CFG.SYS.VERSION .. " ===")
  self:log("INFO", "PWR: " .. (self.C.pwr and "OK" or "MISSING"))
  self:log("INFO", "ELN: " .. (self.C.eln and "OK" or "none"))
end

-- ======================== ACCESSORS ========================

function ReactorCtrl:getState() return self.S end
function ReactorCtrl:getConfig() return self.CFG end
function ReactorCtrl:getComponents() return self.C end
function ReactorCtrl:getLog() return self.S.log end

-- Expose utilities for UI modules
ReactorCtrl.clamp = clamp
ReactorCtrl.pct   = pct
ReactorCtrl.lerp  = lerp
ReactorCtrl.fmtN  = fmtN
ReactorCtrl.fmtT  = fmtT
ReactorCtrl.tSym  = tSym

return ReactorCtrl
