--[[
  PWR Control Room Client v2.0
  Runs on the control room computer with 2 screens + 2 GPUs.
  
  Screen 1 (Primary): Full GUI using lib/GUI.lua - reactor status, controls
  Screen 2 (Secondary): Direct GPU rendering via lib/gpu2.lua - energy, log
  
  Modules:
    lib/GUI.lua         - GUI framework (buttons, labels, panels, progress bars)
    lib/protocol.lua    - Network protocol
    lib/colors.lua      - Nuclear theme colors
    lib/gpu2.lua        - Second GPU rendering helper
  
  Hardware: 2x GPU Tier 3, 2x Screen Tier 3, Network card (modem).
  Run setup_screens.lua first to bind GPUs to screens.
]]

package.path = package.path .. ";/lib/?.lua;/lib/?/init.lua"

local component = require("component")
local event     = require("event")
local computer  = require("computer")
local unicode   = require("unicode")

local Protocol  = require("protocol")
local K         = require("colors")
local gpu2      = require("gpu2")

-- GUI library requires these
require("advancedLua")
local buffer = require("doubleBuffering")
local GUI = require("GUI")

-- ============================ STATE ============================

local S = {
  connected   = false,
  serverAddr  = nil,
  lastMsg     = 0,
  lastConnect = 0,
  statusMsg   = "Disconnected",
  blink       = false,
  blinkTimer  = 0,
  -- Telemetry (populated from server)
  uptime = 0, mode = "INIT",
  coreHeat = 0, hullHeat = 0, heatCap = 10000000, hullCap = 10000000,
  flux = 0, rodLogical = 100, rodTarget = 100,
  fuelAmt = 0, fuelProg = 0, fuelMax = 1,
  coldFill = 0, coldMax = 128000, hotFill = 0, hotMax = 128000,
  radiation = 0,
  turbineSpeed = 0, motorOn = false, alarmOn = false, turbineFault = false,
  heatTargetPct = 0, heatTarget = 0, pidOut = 0, pidIntegral = 0, heatTrend = 0,
  thWarn = 0, thAZ1 = 0, thAZ2 = 0, thScram = 0,
  az1Active = false, az2Active = false,
  scramActive = false, scramReason = "", scramCount = 0,
  sirenOn = false,
  cycleCount = 0, calibrated = false, cfg = {},
  log = {},
}

-- ============================ NETWORKING ============================

local modem = component.modem

local function sendToServer(msg)
  if not modem or not S.serverAddr then return false end
  return pcall(modem.send, S.serverAddr, Protocol.PORT, Protocol.pack(msg.type, msg))
end

local function tryConnect()
  if not modem or S.connected then return end
  local now = computer.uptime()
  if now - S.lastConnect < 2.0 then return end
  S.lastConnect = now
  if S.serverAddr then
    sendToServer({ type = Protocol.MSG.HELLO })
  else
    modem.broadcast(Protocol.PORT, Protocol.pack(Protocol.MSG.HELLO))
  end
end

local function handleServerMessage(data)
  local msg = Protocol.unpack(data)
  if not msg then return end
  S.lastMsg = computer.uptime()

  if msg.type == Protocol.MSG.STATUS then
    S.statusMsg = msg.msg or "OK"; S.connected = true
  elseif msg.type == Protocol.MSG.TELEMETRY then
    S.connected = true; S.statusMsg = "Connected"
    for k, v in pairs(msg) do
      if k ~= "type" and k ~= "log" and k ~= "cfg" then S[k] = v end
    end
    if msg.cfg then S.cfg = msg.cfg end
    if msg.log then S.log = msg.log end
  elseif msg.type == Protocol.MSG.LOG_DATA then
    if msg.entries then S.log = msg.entries end
  end
end

-- ============================ UTILITY ============================

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function pct(v, m) if (m or 0) <= 0 then return 0 end; return clamp(v / m * 100, 0, 100) end

local function hcol(h)
  if h >= S.thScram then return K.RED
  elseif h >= S.thAZ2 then return K.ORANGE
  elseif h >= S.thAZ1 then return K.GOLD
  elseif h >= S.thWarn then return K.YELLOW
  else return K.GREEN end
end

-- ============================ SCREEN 2: GPU2 DIRECT RENDERING ============================

local function drawScreen2()
  if not gpu2.ready then return end
  local W, H = gpu2.w, gpu2.h
  local LW = math.min(W - 2, 78)
  local row = 1

  gpu2.clear(K.BG)

  -- Header
  gpu2.colors(K.HEADER, K.PANEL2)
  gpu2.rect(1, 1, W, 3, K.PANEL2, " ")
  local title = "TURBINE / LOAD FOLLOWING / CONTROLS"
  gpu2.text(math.max(1, math.floor((W - #title) / 2) + 1), 2, K.HEADER, title)
  gpu2.text(2, 1, K.CYAN, string.format("T+%s", S.uptime > 0 and require("reactor_ctrl").fmtT(S.uptime) or "0:00"))

  local connStr = S.connected and "CONNECTED" or "OFFLINE"
  gpu2.text(W - #connStr - 1, 3, S.connected and K.GREEN or K.RED, connStr)
  row = 4

  -- Separator
  gpu2.text(2, row, K.BORDER2, string.rep("=", LW)); row = row + 1

  -- TURBINE section
  gpu2.text(2, row, K.HEADER, " == TURBINE SPEED / LOAD FOLLOWING =================================="); row = row + 1

  local spd = S.turbineSpeed
  local spdCol = K.GREEN
  if spd > (S.cfg.turbineMax or 250) then spdCol = K.RED
  elseif spd > (S.cfg.turbineOptHi or 205) then spdCol = K.ORANGE
  elseif spd < (S.cfg.turbineOptLo or 195) then spdCol = K.YELLOW
  end

  gpu2.text(2, row, K.TEXT2, " Speed:         ")
  local spdStr = string.format("%6.1f / %d rad/s", spd, S.cfg.turbineMax or 250)
  gpu2.text(18, row, spdCol, spdStr)
  gpu2.bar(52, row, 16, spd, S.cfg.turbineMax or 250, spdCol, K.GRAY2)
  row = row + 1

  local optStr = string.format("Optimal: %d-%d rad/s", S.cfg.turbineOptLo or 195, S.cfg.turbineOptHi or 205)
  gpu2.text(2, row, K.TEXT2, " ")
  gpu2.text(18, row, K.CYAN, optStr); row = row + 1

  local motorStr = S.motorOn and "[ RUNNING ]" or "[ OFF ]"
  gpu2.text(2, row, K.TEXT2, " Motor:         ")
  gpu2.text(18, row, S.motorOn and K.GREEN or K.GRAY, motorStr)
  if S.turbineFault then
    gpu2.text(40, row, K.RED, " !! TURBINE FAULT !!")
  end
  row = row + 1

  local alarmStr = S.alarmOn and "[ ACTIVE ]" or "[ OFF ]"
  gpu2.text(2, row, K.TEXT2, " Alarm:         ")
  gpu2.text(18, row, S.alarmOn and K.RED or K.GRAY, alarmStr)
  row = row + 1

  gpu2.text(2, row, K.TEXT2, string.format(" Heat target: %5.1f%%  %s TU",
    S.heatTargetPct, require("reactor_ctrl").fmtN(S.heatTarget))); row = row + 1

  local lfStr = S.cfg.lfEnabled and string.format("AUTO (target:%d rad/s)", S.cfg.lfTarget or 200)
    or "MANUAL"
  gpu2.text(2, row, K.TEXT2, " LF mode:       ")
  gpu2.text(18, row, K.CYAN, lfStr); row = row + 1

  -- Separator
  gpu2.text(2, row, K.BORDER2, string.rep("-", LW)); row = row + 1

  -- THRESHOLDS
  gpu2.text(2, row, K.HEADER, " == THRESHOLDS / CONFIG =============================================="); row = row + 1

  local function rdr(lbl, val, unit, col)
    gpu2.text(2, row, K.TEXT2, string.format(" %-24s", lbl))
    gpu2.text(28, row, col or K.WHITE, tostring(val) .. " " .. (unit or ""))
    row = row + 1
  end

  rdr("heatCap:", require("reactor_ctrl").fmtN(S.heatCap), "TU", K.WHITE)
  rdr("PWR_MIN -> MAX:", require("reactor_ctrl").fmtN(S.cfg.pwrMin or 0) .. "->" .. require("reactor_ctrl").fmtN(S.cfg.pwrMax or 0), "TU", K.CYAN)
  rdr("WARN (75%):", require("reactor_ctrl").fmtN(S.thWarn), "TU", K.YELLOW)
  rdr("AZ-1  (85%):", require("reactor_ctrl").fmtN(S.thAZ1), "TU", K.GOLD)
  rdr("AZ-2  (92%):", require("reactor_ctrl").fmtN(S.thAZ2), "TU", K.ORANGE)
  rdr("SCRAM (96%):", require("reactor_ctrl").fmtN(S.thScram), "TU", K.RED)
  row = row + 1

  -- CONTROLS
  gpu2.text(2, row, K.BORDER2, string.rep("-", LW)); row = row + 1
  gpu2.text(2, row, K.HEADER, " == CONTROLS ========================================================"); row = row + 1
  gpu2.text(2, row, K.TEXT2, " Commands (on Screen 1):"); row = row + 1
  gpu2.text(4, row, K.CYAN, "[S]START [X]STOP [R]SCRAM [1-9]Power [C]Cal"); row = row + 1

  row = row + 1

  -- EVENT LOG
  gpu2.text(2, row, K.BORDER2, string.rep("-", LW)); row = row + 1
  gpu2.text(2, row, K.HEADER, " == EVENT LOG ========================================================"); row = row + 1

  local logStart = math.max(1, #S.log - (H - row - 2))
  for i = logStart, #S.log do
    local e = S.log[i]
    if row > H - 1 then break end
    local c = K.TEXT
    if e.lvl == "WRN" then c = K.YELLOW
    elseif e.lvl == "ERR" then c = K.ORANGE
    elseif e.lvl == "!!!" then c = K.RED end
    gpu2.text(2, row, K.GRAY, "[" .. (e.t or "") .. "]")
    gpu2.text(12, row, c, "[" .. (e.lvl or "") .. "] " .. (e.msg or ""))
    row = row + 1
  end

  -- Footer
  gpu2.rect(1, H, W, 1, K.DGRAY, " ")
  gpu2.text(1, H, K.TEXT2, " Turbine Panel | " .. S.statusMsg)
end

-- ============================ SCREEN 1: GUI LIBRARY ============================

local function fmtT(sec)
  sec = math.floor(sec or 0)
  local h = math.floor(sec / 3600); local m = math.floor((sec % 3600) / 60); local s = sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

local function fmtN(n)
  n = math.floor(n or 0)
  local s = tostring(math.abs(n)); local r, l = "", #s
  for i = 1, l do r = r .. s:sub(i, i); if (l - i) % 3 == 0 and i < l then r = r .. "," end end
  return (n < 0 and "-" or "") .. r
end

local function createScreen1UI()
  local app = GUI.application(1, 1, buffer.getResolution())

  -- Background
  app:addChild(GUI.panel(1, 1, app.width, app.height, K.BG))

  -- Header
  app:addChild(GUI.panel(1, 1, app.width, 3, K.PANEL2))
  local titleLabel = app:addChild(GUI.label(1, 2, app.width, 1, K.HEADER, "PWR REACTOR STATUS"))
  titleLabel:setAlignment(GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)

  local uptimeLabel = app:addChild(GUI.label(2, 1, 20, 1, K.CYAN, "T+0:00"))
  local modeLabel = app:addChild(GUI.label(app.width - 20, 2, 18, 1, K.GRAY, "[ INIT ]"))
  modeLabel:setAlignment(GUI.ALIGNMENT_HORIZONTAL_RIGHT, GUI.ALIGNMENT_VERTICAL_TOP)

  local statusLabel = app:addChild(GUI.label(2, 3, 40, 1, K.TEXT2, "Disconnected"))
  local cycleLabel = app:addChild(GUI.label(app.width - 40, 3, 38, 1, K.TEXT2, ""))
  cycleLabel:setAlignment(GUI.ALIGNMENT_HORIZONTAL_RIGHT, GUI.ALIGNMENT_VERTICAL_TOP)

  -- Separator
  app:addChild(GUI.panel(1, 4, app.width, 1, K.BORDER2)):setAlignment()

  -- REACTOR section
  local y = 5
  app:addChild(GUI.label(2, y, 60, 1, K.HEADER, "== REACTOR =========")); y = y + 1

  local coreHeatLabel = app:addChild(GUI.label(2, y, 16, 1, K.TEXT2, " Core heat:    "))
  local coreHeatVal = app:addChild(GUI.label(18, y, 30, 1, K.GREEN, "---"))
  y = y + 1

  local coreHeatBar = app:addChild(GUI.progressBar(18, y, 20, K.GREEN, K.GRAY2, K.WHITE, 0, false, false))
  y = y + 1

  local hullLabel = app:addChild(GUI.label(2, y, 16, 1, K.TEXT2, " Hull heat:    "))
  local hullVal = app:addChild(GUI.label(18, y, 30, 1, K.GREEN, "---"))
  y = y + 1

  local hullBar = app:addChild(GUI.progressBar(18, y, 20, K.GREEN, K.GRAY2, K.WHITE, 0, false, false))
  y = y + 1

  local fluxLabel = app:addChild(GUI.label(2, y, 16, 1, K.TEXT2, " Neutron flux: "))
  local fluxVal = app:addChild(GUI.label(18, y, 30, 1, K.BLUE, "---"))
  y = y + 1

  local rodLabel = app:addChild(GUI.label(2, y, 16, 1, K.TEXT2, " Rods (log):   "))
  local rodVal = app:addChild(GUI.label(18, y, 50, 1, K.CYAN, "---"))
  y = y + 1

  local pidLabel = app:addChild(GUI.label(2, y, 70, 1, K.TEXT2, ""))
  y = y + 1

  -- Separator
  app:addChild(GUI.panel(1, y, app.width, 1, K.BORDER2)):setAlignment(); y = y + 1

  -- TURBINE / PROTECTION
  app:addChild(GUI.label(2, y, 60, 1, K.HEADER, "== TURBINE / PROTECTION ==")); y = y + 1

  local turbineLabel = app:addChild(GUI.label(2, y, 50, 1, K.TEXT2, " Turbine: ---"))
  y = y + 1
  local motorLabel = app:addChild(GUI.label(2, y, 50, 1, K.TEXT2, " Motor: ---"))
  y = y + 1
  local alarmLabel = app:addChild(GUI.label(2, y, 50, 1, K.TEXT2, " Alarm: ---"))
  y = y + 1
  local fuelLabel = app:addChild(GUI.label(2, y, 50, 1, K.TEXT2, " Fuel: ---"))
  y = y + 1
  local radLabel = app:addChild(GUI.label(2, y, 50, 1, K.TEXT2, " Radiation: ---"))
  y = y + 1
  local coolLabel = app:addChild(GUI.label(2, y, 60, 1, K.TEXT2, " Coolant: ---"))
  y = y + 1

  y = y + 1

  local az1Label = app:addChild(GUI.label(2, y, 30, 1, K.GRAY, " AZ-1: [ OK ]")); y = y + 1
  local az2Label = app:addChild(GUI.label(2, y, 30, 1, K.GRAY, " AZ-2: [ OK ]")); y = y + 1
  local scramLabel = app:addChild(GUI.label(2, y, 30, 1, K.GRAY, " SCRM: [ OK ]")); y = y + 1

  -- SCRAM banner
  y = y + 1
  local scramBanner = app:addChild(GUI.label(2, y, app.width - 2, 1, K.RED, ""))
  y = y + 1

  -- Control buttons
  app:addChild(GUI.panel(1, y, app.width, 1, K.BORDER2)):setAlignment(); y = y + 1
  app:addChild(GUI.label(2, y, 60, 1, K.HEADER, "== CONTROLS ==")); y = y + 1

  local btnStart = app:addChild(GUI.button(2, y, 12, 1, K.GREEN2, K.WHITE, K.GREEN, K.WHITE, "START"))
  local btnStop = app:addChild(GUI.button(15, y, 12, 1, K.YELLOW, K.DGRAY, K.GOLD, K.WHITE, "STOP"))
  local btnScram = app:addChild(GUI.button(28, y, 12, 1, K.RED, K.WHITE, K.RED2, K.WHITE, "SCRAM"))
  local btnRecal = app:addChild(GUI.button(41, y, 12, 1, K.CYAN, K.DGRAY, K.BLUE, K.WHITE, "RECAL"))
  y = y + 1

  -- Power slider label
  local pwrLabel = app:addChild(GUI.label(2, y, 30, 1, K.TEXT2, " Power setpoint:"))
  y = y + 1
  local pwrSlider = app:addChild(GUI.slider(2, y, 50, K.GREEN, K.GRAY2, K.WHITE, K.CYAN, 0, 100, 50, true, "", "%"))
  pwrSlider.roundValues = true

  -- Footer
  app:addChild(GUI.panel(1, app.height, app.width, 1, K.DGRAY))
  local footerLabel = app:addChild(GUI.label(2, app.height, app.width, 1, K.TEXT2, " PWR Control Room v2.1 "))

  -- ======================== EVENT HANDLERS ========================

  local function sendCmd(msg)
    sendToServer(msg)
    S.statusMsg = msg.type .. " sent"
  end

  btnStart.onTouch = function() sendCmd({ type = Protocol.MSG.START }) end
  btnStop.onTouch = function() sendCmd({ type = Protocol.MSG.STOP }) end
  btnScram.onTouch = function()
    if S.scramActive then sendCmd({ type = Protocol.MSG.RESET })
    else sendCmd({ type = Protocol.MSG.SCRAM }) end
  end
  btnRecal.onTouch = function() sendCmd({ type = Protocol.MSG.RECALIBRATE }) end

  pwrSlider.onValueChanged = function(_, slider)
    sendCmd({ type = Protocol.MSG.SET_POWER, value = slider.value })
  end

  -- Keyboard handler
  app.eventHandler = function(application, object, e1, e2, e3, e4, ...)
    if e1 == "key_down" then
      local ch = string.char(e4 or 0):lower()
      if ch == "s" then sendCmd({ type = Protocol.MSG.START })
      elseif ch == "x" then sendCmd({ type = Protocol.MSG.STOP })
      elseif ch == "r" then
        if S.scramActive then sendCmd({ type = Protocol.MSG.RESET })
        else sendCmd({ type = Protocol.MSG.SCRAM }) end
      elseif ch == "c" then sendCmd({ type = Protocol.MSG.RECALIBRATE })
      elseif ch >= "1" and ch <= "9" then
        sendCmd({ type = Protocol.MSG.SET_POWER, value = tonumber(ch) * 10 })
      elseif ch == "0" then
        sendCmd({ type = Protocol.MSG.SET_POWER, value = 100 })
      elseif ch == "q" then
        application:stop()
      end
    elseif e1 == "modem_message" then
      local from, port, _, data = e2, e3, e4, e5
      if port == Protocol.PORT and data then
        handleServerMessage(data)
      end
    end
  end

  -- ======================== UPDATE LOOP ========================

  local function updateUI()
    -- Header
    uptimeLabel.text = "T+" .. fmtT(S.uptime)

    local modeColors = {
      INIT = K.GRAY, IDLE = K.CYAN, STARTUP = K.BLUE, POWER = K.GREEN,
      SHUTDOWN = K.YELLOW, SCRAM = K.RED, FAULT = K.RED, CALIBRATE = 0xAA44FF,
    }
    modeLabel.text = "[ " .. S.mode .. " ]"
    modeLabel.colors.text = modeColors[S.mode] or K.GRAY

    statusLabel.text = S.statusMsg
    cycleLabel.text = "Cycles: " .. S.cycleCount .. (S.calibrated and "" or " [!NO CALIB]")

    -- Reactor
    coreHeatVal.text = fmtN(S.coreHeat) .. " TU  " .. string.format("%.1f%%", pct(S.coreHeat, S.heatCap))
    coreHeatVal.colors.text = hcol(S.coreHeat)
    coreHeatBar.value = pct(S.coreHeat, S.heatCap)
    coreHeatBar.colors.active = hcol(S.coreHeat)

    hullVal.text = fmtN(S.hullHeat) .. " TU  " .. string.format("%.1f%%", pct(S.hullHeat, S.hullCap))
    hullVal.colors.text = hcol(S.hullHeat)
    hullBar.value = pct(S.hullHeat, S.hullCap)
    hullBar.colors.active = hcol(S.hullHeat)

    fluxVal.text = string.format("%.1f", S.flux)
    fluxVal.colors.text = S.flux > 500 and K.PINK or K.BLUE

    local rPct = 100 - S.rodLogical
    rodVal.text = string.format("%.1f%%  react:%.1f%%  target:%.1f%%", S.rodLogical, rPct, S.rodTarget)
    rodVal.colors.text = rPct > 70 and K.ORANGE or (rPct > 30 and K.YELLOW or K.GREEN2)

    pidLabel.text = string.format(" PID: %+.6f%%/tick  Sigma: %.0f", S.pidOut, S.pidIntegral)

    -- Turbine
    local spdCol = K.GREEN
    if S.turbineSpeed > (S.cfg.turbineMax or 250) then spdCol = K.RED
    elseif S.turbineSpeed > (S.cfg.turbineOptHi or 205) then spdCol = K.ORANGE
    elseif S.turbineSpeed < (S.cfg.turbineOptLo or 195) then spdCol = K.YELLOW
    end
    turbineLabel.text = string.format(" Turbine: %.1f / %d rad/s", S.turbineSpeed, S.cfg.turbineMax or 250)
    turbineLabel.colors.text = spdCol

    motorLabel.text = string.format(" Motor: %s", S.motorOn and "RUNNING" or "OFF")
    motorLabel.colors.text = S.motorOn and K.GREEN or K.GRAY
    if S.turbineFault then
      motorLabel.text = motorLabel.text .. " !! FAULT !!"
      motorLabel.colors.text = K.RED
    end

    alarmLabel.text = string.format(" Alarm: %s", S.alarmOn and "ACTIVE" or "OFF")
    alarmLabel.colors.text = S.alarmOn and K.RED or K.GRAY

    -- Fuel / Coolant
    local fp = (S.fuelAmt > 0 and S.fuelMax > 0) and pct(S.fuelProg, S.fuelMax) or 0
    fuelLabel.text = string.format(" Fuel: %d pcs. Burnup: %.1f%%", S.fuelAmt, fp)
    fuelLabel.colors.text = fp < 20 and K.GREEN or (fp < 90 and K.YELLOW or K.RED)

    local radc = S.radiation >= 500 and K.RED or (S.radiation >= 100 and K.YELLOW or K.GREEN2)
    radLabel.text = string.format(" Radiation: %.0f rad/t", S.radiation)
    radLabel.colors.text = radc

    coolLabel.text = string.format(" Cool.cold: %.1f%%  Cool.hot: %.1f%%",
      pct(S.coldFill, S.coldMax), pct(S.hotFill, S.hotMax))

    -- Protection
    az1Label.text = string.format(" AZ-1: %s", S.az1Active and "[!! ACTIVE!!]" or "[ OK ]")
    az1Label.colors.text = S.az1Active and K.RED or K.GRAY

    az2Label.text = string.format(" AZ-2: %s", S.az2Active and "[!! ACTIVE!!]" or "[ OK ]")
    az2Label.colors.text = S.az2Active and K.ORANGE or K.GRAY

    scramLabel.text = string.format(" SCRM: %s", S.scramActive and "[!!! ALARM!!!]" or "[ OK ]")
    scramLabel.colors.text = S.scramActive and K.RED or K.GRAY

    if S.scramActive then
      scramBanner.text = " !!! SCRAM: " .. S.scramReason .. " !!! "
      scramBanner.colors.text = S.blink and K.WHITE or K.RED
    else
      scramBanner.text = ""
    end

    -- Power slider sync
    if math.abs(pwrSlider.value - (S.heatTargetPct or 50)) > 1 then
      pwrSlider.value = S.heatTargetPct or 50
    end
  end

  return app, updateUI
end

-- ============================ MAIN ============================

local function main()
  print("PWR Control Room Client v2.1")
  print("Initializing dual-GPU setup...")

  -- Init secondary GPU
  local w2, h2 = gpu2.init()
  io.write(string.format("Screen 2: GPU2 %dx%d\n", w2, h2))

  -- Init primary GPU via doubleBuffering (GUI library)
  buffer.clear(K.BG)
  buffer.drawChanges()

  -- Open modem
  modem.open(Protocol.PORT)
  io.write("Modem port " .. Protocol.PORT .. " opened\n")

  -- Create Screen 1 GUI
  local app, updateUI = createScreen1UI()

  -- Initial draws
  gpu2.clear(K.BG)
  gpu2.text(1, 1, K.TEXT, "Connecting to reactor server...")
  app:draw(true)

  io.write("Connecting to reactor server...\n")

  -- Run GUI application with modem_message handling
  app:start(0.2)
end

-- Entry point
local ok, err = pcall(main)
if not ok then
  print("\n[FATAL] " .. tostring(err))
end
