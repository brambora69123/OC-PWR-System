--[[
  PWR Control Room Client v2.2
  Runs on the control room computer with 2 screens + 2 GPUs.
  
  Screen 1 (Primary): Reactor status, controls - direct GPU rendering
  Screen 2 (Secondary): Turbine speed, event log - direct GPU rendering
  
  Modules:
    lib/protocol.lua    - Network protocol
    lib/colors.lua      - Nuclear theme colors
  
  Hardware: 2x GPU Tier 3, 2x Screen Tier 3, Network card (modem).
  Run setup_screens.lua first to bind GPUs to screens.
]]

package.path = package.path .. ";/home/pwr/lib/?.lua;/home/pwr/lib/?/init.lua"

local component = require("component")
local event     = require("event")
local computer  = require("computer")

local Protocol  = require("protocol")
local K         = require("colors")

-- ============================ GPU HELPER ============================

local function makeGPU(addr)
  local gpu
  if addr then
    gpu = component.proxy(addr)
  else
    gpu = component.gpu
  end
  if not gpu then return nil end
  local maxW, maxH = gpu.maxResolution()
  gpu.setResolution(maxW, maxH)
  local w, h = gpu.getResolution()
  return {
    gpu = gpu, w = w, h = h,
    fg = function(c) pcall(gpu.setForeground, c) end,
    bg = function(c) pcall(gpu.setBackground, c) end,
    colors = function(fg, bg)
      if fg then pcall(gpu.setForeground, fg) end
      if bg then pcall(gpu.setBackground, bg) end
    end,
    text = function(x, y, color, str)
      if str then
        if color then pcall(gpu.setForeground, color) end
        pcall(gpu.set, x, y, tostring(str))
      end
    end,
    rect = function(x, y, w, h, bgColor, char)
      if bgColor then pcall(gpu.setBackground, bgColor) end
      pcall(gpu.fill, x, y, w, h or 1, char or " ")
    end,
    bar = function(x, y, w, value, maxVal, ac, pc)
      local n = math.floor(math.max(0, math.min(100, value / math.max(maxVal, 1) * 100)) / 100 * w)
      pcall(gpu.setForeground, ac)
      pcall(gpu.setBackground, pc)
      pcall(gpu.set, x, y, string.rep("#", n) .. string.rep(".", w - n))
    end,
    clear = function(bgColor)
      if bgColor then pcall(gpu.setBackground, bgColor) end
      pcall(gpu.fill, 1, 1, w, h, " ")
    end,
  }
end

-- ============================ STATE ============================

local S = {
  connected   = false,
  serverAddr  = nil,
  lastMsg     = 0,
  lastConnect = 0,
  statusMsg   = "Disconnected",
  blink       = false,
  blinkTimer  = 0,
  -- Telemetry
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

local function fmtN(n)
  n = math.floor(n or 0)
  local s = tostring(math.abs(n)); local r, l = "", #s
  for i = 1, l do r = r .. s:sub(i, i); if (l - i) % 3 == 0 and i < l then r = r .. "," end end
  return (n < 0 and "-" or "") .. r
end

local function fmtT(sec)
  sec = math.floor(sec or 0)
  local h = math.floor(sec / 3600); local m = math.floor((sec % 3600) / 60); local s = sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

local function hcol(h)
  if h >= S.thScram then return K.RED
  elseif h >= S.thAZ2 then return K.ORANGE
  elseif h >= S.thAZ1 then return K.GOLD
  elseif h >= S.thWarn then return K.YELLOW
  else return K.GREEN end
end

local function sendCmd(msg)
  sendToServer(msg)
  S.statusMsg = msg.type .. " sent"
end

-- ============================ SCREEN 2: TURBINE / LOG ============================

local function drawScreen2(g)
  if not g then return end
  local W, H = g.w, g.h
  local LW = math.min(W - 2, 78)
  local row = 1

  g.clear(K.BG)

  -- Header
  g.rect(1, 1, W, 3, K.PANEL2, " ")
  local title = "TURBINE / LOAD FOLLOWING"
  g.text(math.max(1, math.floor((W - #title) / 2) + 1), 2, K.HEADER, title)
  g.text(2, 1, K.CYAN, string.format("T+%s", fmtT(S.uptime)))
  local connStr = S.connected and "CONNECTED" or "OFFLINE"
  g.text(W - #connStr - 1, 3, S.connected and K.GREEN or K.RED, connStr)
  row = 4

  g.text(2, row, K.BORDER2, string.rep("=", LW)); row = row + 1

  -- TURBINE
  g.text(2, row, K.HEADER, " == TURBINE SPEED / LOAD FOLLOWING ================"); row = row + 1

  local spd = S.turbineSpeed
  local spdCol = K.GREEN
  if spd > (S.cfg.turbineMax or 250) then spdCol = K.RED
  elseif spd > (S.cfg.turbineOptHi or 205) then spdCol = K.ORANGE
  elseif spd < (S.cfg.turbineOptLo or 195) then spdCol = K.YELLOW end

  g.text(2, row, K.TEXT2, " Speed: ")
  g.text(12, row, spdCol, string.format("%6.1f / %d rad/s", spd, S.cfg.turbineMax or 250))
  g.bar(48, row, 20, spd, S.cfg.turbineMax or 250, spdCol, K.GRAY2)
  row = row + 1

  g.text(2, row, K.TEXT2, " ")
  g.text(12, row, K.CYAN, string.format("Optimal: %d-%d rad/s", S.cfg.turbineOptLo or 195, S.cfg.turbineOptHi or 205))
  row = row + 1

  g.text(2, row, K.TEXT2, " Motor: ")
  g.text(12, row, S.motorOn and K.GREEN or K.GRAY, S.motorOn and "[ RUNNING ]" or "[ OFF     ]")
  if S.turbineFault then g.text(30, row, K.RED, "!! FAULT !!") end
  row = row + 1

  g.text(2, row, K.TEXT2, " Alarm: ")
  g.text(12, row, S.alarmOn and K.RED or K.GRAY, S.alarmOn and "[ ACTIVE ]" or "[ OFF    ]")
  row = row + 1

  g.text(2, row, K.TEXT2, string.format(" Heat target: %5.1f%%  %s TU", S.heatTargetPct, fmtN(S.heatTarget)))
  row = row + 1

  g.text(2, row, K.TEXT2, " LF mode: ")
  local lfStr = S.cfg.lfEnabled and string.format("AUTO (target:%d rad/s)", S.cfg.lfTarget or 200) or "MANUAL"
  g.text(12, row, K.CYAN, lfStr)
  row = row + 1

  g.text(2, row, K.BORDER2, string.rep("-", LW)); row = row + 1

  -- THRESHOLDS
  g.text(2, row, K.HEADER, " == THRESHOLDS / CONFIG ============================"); row = row + 1

  local function rdr(lbl, val, unit, col)
    g.text(2, row, K.TEXT2, string.format(" %-22s", lbl))
    g.text(26, row, col or K.WHITE, tostring(val) .. " " .. (unit or ""))
    row = row + 1
  end

  rdr("heatCap:", fmtN(S.heatCap), "TU", K.WHITE)
  rdr("PWR_MIN -> MAX:", fmtN(S.cfg.pwrMin or 0) .. "->" .. fmtN(S.cfg.pwrMax or 0), "TU", K.CYAN)
  rdr("WARN (75%):", fmtN(S.thWarn), "TU", K.YELLOW)
  rdr("AZ-1  (85%):", fmtN(S.thAZ1), "TU", K.GOLD)
  rdr("AZ-2  (92%):", fmtN(S.thAZ2), "TU", K.ORANGE)
  rdr("SCRAM (96%):", fmtN(S.thScram), "TU", K.RED)
  row = row + 1

  -- KEYBOARD
  g.text(2, row, K.BORDER2, string.rep("-", LW)); row = row + 1
  g.text(2, row, K.HEADER, " == KEYBOARD ========================================"); row = row + 1
  g.text(4, row, K.CYAN, "[S]START [X]STOP [R]SCRAM [1-9]Power [C]Cal"); row = row + 1
  row = row + 1

  -- EVENT LOG
  g.text(2, row, K.BORDER2, string.rep("-", LW)); row = row + 1
  g.text(2, row, K.HEADER, " == EVENT LOG ========================================"); row = row + 1

  local logStart = math.max(1, #S.log - (H - row - 2))
  for i = logStart, #S.log do
    local e = S.log[i]
    if row > H - 1 then break end
    local c = K.TEXT
    if e.lvl == "WRN" then c = K.YELLOW
    elseif e.lvl == "ERR" then c = K.ORANGE
    elseif e.lvl == "!!!" then c = K.RED end
    g.text(2, row, K.GRAY, "[" .. (e.t or "") .. "]")
    g.text(12, row, c, "[" .. (e.lvl or "") .. "] " .. (e.msg or ""))
    row = row + 1
  end

  -- Footer
  g.rect(1, H, W, 1, K.DGRAY, " ")
  g.text(1, H, K.TEXT2, " Turbine Panel | " .. S.statusMsg)
end

-- ============================ SCREEN 1: REACTOR STATUS ============================

local function drawScreen1(g)
  if not g then return end
  local W, H = g.w, g.h
  local LW = math.min(W - 2, 78)
  local row = 1

  g.clear(K.BG)

  -- Header
  g.rect(1, 1, W, 3, K.PANEL2, " ")
  local title = "PWR REACTOR STATUS"
  g.text(math.max(1, math.floor((W - #title) / 2) + 1), 2, K.HEADER, title)
  g.text(2, 1, K.CYAN, string.format("T+%s", fmtT(S.uptime)))

  local modeColors = {
    INIT = K.GRAY, IDLE = K.CYAN, STARTUP = K.BLUE, POWER = K.GREEN,
    SHUTDOWN = K.YELLOW, SCRAM = K.RED, FAULT = K.RED, CALIBRATE = 0xAA44FF,
  }
  local modeStr = "[ " .. S.mode .. " ]"
  g.text(W - #modeStr - 1, 2, modeColors[S.mode] or K.GRAY, modeStr)
  g.text(2, 3, K.TEXT2, S.statusMsg)
  g.text(W - 30, 3, K.TEXT2, "Cycles: " .. S.cycleCount .. (S.calibrated and "" or " [!NO CAL]"))
  row = 4

  g.text(2, row, K.BORDER2, string.rep("=", LW)); row = row + 1

  -- REACTOR
  g.text(2, row, K.HEADER, " == REACTOR ========================================="); row = row + 1

  g.text(2, row, K.TEXT2, " Core heat:  ")
  g.text(16, row, hcol(S.coreHeat), string.format("%s TU  %.1f%%", fmtN(S.coreHeat), pct(S.coreHeat, S.heatCap)))
  row = row + 1
  g.bar(16, row, 20, S.coreHeat, S.heatCap, hcol(S.coreHeat), K.GRAY2)
  row = row + 1

  g.text(2, row, K.TEXT2, " Hull heat:  ")
  g.text(16, row, hcol(S.hullHeat), string.format("%s TU  %.1f%%", fmtN(S.hullHeat), pct(S.hullHeat, S.hullCap)))
  row = row + 1
  g.bar(16, row, 20, S.hullHeat, S.hullCap, hcol(S.hullHeat), K.GRAY2)
  row = row + 1

  g.text(2, row, K.TEXT2, " Flux:       ")
  g.text(16, row, S.flux > 500 and K.PINK or K.BLUE, string.format("%.1f", S.flux))
  row = row + 1

  local rPct = 100 - S.rodLogical
  g.text(2, row, K.TEXT2, " Rods:       ")
  g.text(16, row, rPct > 70 and K.ORANGE or (rPct > 30 and K.YELLOW or K.GREEN2),
    string.format("log:%.1f%%  react:%.1f%%  tgt:%.1f%%", S.rodLogical, rPct, S.rodTarget))
  row = row + 1

  g.text(2, row, K.TEXT2, string.format(" PID: %+.6f%%/tick  Sigma: %.0f", S.pidOut, S.pidIntegral))
  row = row + 1

  g.text(2, row, K.BORDER2, string.rep("-", LW)); row = row + 1

  -- TURBINE / PROTECTION
  g.text(2, row, K.HEADER, " == TURBINE / PROTECTION ============================"); row = row + 1

  local spdCol = K.GREEN
  if S.turbineSpeed > (S.cfg.turbineMax or 250) then spdCol = K.RED
  elseif S.turbineSpeed > (S.cfg.turbineOptHi or 205) then spdCol = K.ORANGE
  elseif S.turbineSpeed < (S.cfg.turbineOptLo or 195) then spdCol = K.YELLOW end

  g.text(2, row, K.TEXT2, " Turbine:  ")
  g.text(14, row, spdCol, string.format("%.1f / %d rad/s", S.turbineSpeed, S.cfg.turbineMax or 250))
  row = row + 1

  g.text(2, row, K.TEXT2, " Motor:    ")
  g.text(14, row, S.motorOn and K.GREEN or K.GRAY, S.motorOn and "RUNNING" or "OFF")
  if S.turbineFault then g.text(28, row, K.RED, "!! FAULT !!") end
  row = row + 1

  g.text(2, row, K.TEXT2, " Alarm:    ")
  g.text(14, row, S.alarmOn and K.RED or K.GRAY, S.alarmOn and "ACTIVE" or "OFF")
  row = row + 1

  local fp = (S.fuelAmt > 0 and S.fuelMax > 0) and pct(S.fuelProg, S.fuelMax) or 0
  g.text(2, row, K.TEXT2, " Fuel:     ")
  g.text(14, row, fp < 20 and K.GREEN or (fp < 90 and K.YELLOW or K.RED),
    string.format("%d pcs  Burnup: %.1f%%", S.fuelAmt, fp))
  row = row + 1

  g.text(2, row, K.TEXT2, " Radiation:")
  g.text(14, row, S.radiation >= 500 and K.RED or (S.radiation >= 100 and K.YELLOW or K.GREEN2),
    string.format("%.0f rad/t", S.radiation))
  row = row + 1

  g.text(2, row, K.TEXT2, " Coolant:  ")
  g.text(14, row, K.CYAN, string.format("cold:%.1f%%  hot:%.1f%%", pct(S.coldFill, S.coldMax), pct(S.hotFill, S.hotMax)))
  row = row + 1

  row = row + 1

  g.text(2, row, K.TEXT2, " AZ-1: ")
  g.text(10, row, S.az1Active and K.RED or K.GRAY, S.az1Active and "[!! ACTIVE!!]" or "[ OK ]")
  g.text(30, row, K.TEXT2, " AZ-2: ")
  g.text(38, row, S.az2Active and K.ORANGE or K.GRAY, S.az2Active and "[!! ACTIVE!!]" or "[ OK ]")
  g.text(56, row, K.TEXT2, " SCRM: ")
  g.text(64, row, S.scramActive and K.RED or K.GRAY, S.scramActive and "[!!! ALARM!!!]" or "[ OK ]")
  row = row + 1

  row = row + 1

  -- SCRAM banner
  if S.scramActive then
    local banner = " !!! SCRAM: " .. S.scramReason .. " !!! "
    g.text(math.max(1, math.floor((W - #banner) / 2) + 1), row, S.blink and K.WHITE or K.RED, banner)
    row = row + 1
  end

  g.text(2, row, K.BORDER2, string.rep("-", LW)); row = row + 1

  -- CONTROLS
  g.text(2, row, K.HEADER, " == CONTROLS ========================================"); row = row + 1

  g.text(4, row, K.GREEN2, "[S]START")
  g.text(16, row, K.YELLOW, "[X]STOP")
  g.text(28, row, K.RED, "[R]SCRAM")
  g.text(42, row, K.CYAN, "[C]CAL")
  row = row + 1

  g.text(4, row, K.CYAN, "[1-9]Power 10-90%  [0]Power 100%  [Q]Quit")
  row = row + 1

  row = row + 1

  g.text(2, row, K.TEXT2, string.format(" Heat target: %5.1f%%  LF: %s", S.heatTargetPct,
    S.cfg.lfEnabled and string.format("AUTO %d rad/s", S.cfg.lfTarget or 200) or "MANUAL"))
  row = row + 1

  -- Footer
  g.rect(1, H, W, 1, K.DGRAY, " ")
  g.text(1, H, K.TEXT2, " PWR Control Room v2.2 | " .. S.statusMsg)
end

-- ============================ MAIN ============================

local function main()
  print("PWR Control Room Client v2.2")
  print("Initializing dual-GPU setup...")

  -- Find GPUs
  local primaryGPU = component.gpu
  local secondaryGPU = nil
  local primaryAddr = primaryGPU and primaryGPU.getScreen() or nil
  for addr in component.list("gpu") do
    if addr ~= primaryAddr then
      secondaryGPU = component.proxy(addr)
      break
    end
  end
  if not secondaryGPU then secondaryGPU = primaryGPU end

  local g1 = makeGPU(primaryGPU.address)
  local g2 = makeGPU(secondaryGPU.address)

  io.write(string.format("Screen 1: %dx%d\n", g1.w, g1.h))
  io.write(string.format("Screen 2: %dx%d\n", g2.w, g2.h))

  modem.open(Protocol.PORT)
  io.write("Modem port " .. Protocol.PORT .. " opened\n")
  io.write("Connecting to reactor server...\n")

  g1.clear(K.BG)
  g1.text(1, 1, K.TEXT, "Connecting to reactor server...")
  g2.clear(K.BG)
  g2.text(1, 1, K.TEXT, "Connecting...")

  local running = true
  local lastDraw = 0

  while running do
    local now = computer.uptime()

    -- Blink timer
    S.blinkTimer = S.blinkTimer + 0.2
    if S.blinkTimer >= 0.5 then S.blink = not S.blink; S.blinkTimer = 0 end

    -- Try connect
    if not S.connected then tryConnect() end

    -- Timeout
    if S.connected and now - S.lastMsg > 60 then
      S.connected = false; S.statusMsg = "Connection lost"
    end

    -- Draw at ~5 FPS
    if now - lastDraw >= 0.2 then
      lastDraw = now
      drawScreen1(g1)
      drawScreen2(g2)
    end

    -- Events
    local ev = table.pack(event.pull(0.2))
    if ev[1] == "modem_message" then
      local from, port, _, data = ev[2], ev[3], ev[4], ev[5]
      if port == Protocol.PORT and data then
        handleServerMessage(data)
      end
    elseif ev[1] == "key_down" then
      local ch = string.char(ev[3] or 0):lower()
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
        running = false
      end
    end
  end

  print("\nPWR Control Room stopped.")
end

local ok, err = pcall(main)
if not ok then
  print("\n[FATAL] " .. tostring(err))
end
