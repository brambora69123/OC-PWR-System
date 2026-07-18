--[[
  PWR Screen Setup Utility
  Run this ONCE on the control room computer to bind GPUs to screens.
  
  Usage:
    1. Place 2 GPU Tier 3 and 2 Screen Tier 3 on the control room computer
    2. Run this script:  edit setup_screens  then paste and run
    3. After binding is done, run control_client.lua
  
  This script detects all GPUs and screens, binds them in order,
  and sets each to maximum resolution.
]]

local component = require("component")
local term = require("term")

term.clear()
print("=== PWR Screen Setup Utility ===")
print()

-- Find all GPUs
local gpuAddrs = {}
for addr in component.list("gpu") do
  table.insert(gpuAddrs, addr)
end
table.sort(gpuAddrs)

-- Find all screens
local scrAddrs = {}
for addr in component.list("screen") do
  table.insert(scrAddrs, addr)
end
table.sort(scrAddrs)

print(string.format("Found %d GPU(s) and %d Screen(s)", #gpuAddrs, #scrAddrs))
print()

if #gpuAddrs == 0 then
  print("ERROR: No GPUs found! Install at least 1 GPU.")
  return
end

if #scrAddrs == 0 then
  print("ERROR: No screens found! Install at least 1 screen.")
  return
end

print("GPU addresses:")
for i, addr in ipairs(gpuAddrs) do
  local gpu = component.proxy(addr)
  local w, h = gpu.maxResolution()
  print(string.format("  [%d] %s  (max: %dx%d)", i, addr:sub(1, 12), w, h))
end

print()
print("Screen addresses:")
for i, addr in ipairs(scrAddrs) do
  print(string.format("  [%d] %s", i, addr:sub(1, 12)))
end

print()

-- Bind GPUs to screens in order
local bindCount = math.min(#gpuAddrs, #scrAddrs)
print(string.format("Binding %d GPU(s) to Screen(s)...", bindCount))
print()

for i = 1, bindCount do
  local gpu = component.proxy(gpuAddrs[i])
  local scrAddr = scrAddrs[i]
  
  -- Bind GPU to screen
  local ok, err = gpu.bind(scrAddr)
  if ok then
    -- Set to maximum resolution
    local maxW, maxH = gpu.maxResolution()
    gpu.setResolution(maxW, maxH)
    local w, h = gpu.getResolution()
    
    -- Clear screen
    gpu.setForeground(0x00FF80)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, w, h, " ")
    gpu.set(1, 1, string.format("GPU %d -> Screen %d", i, i))
    gpu.set(1, 2, string.format("Resolution: %dx%d", w, h))
    gpu.set(1, 3, string.format("GPU addr: %s", gpuAddrs[i]:sub(1, 12)))
    gpu.set(1, 4, string.format("Screen addr: %s", scrAddr:sub(1, 12)))
    
    print(string.format("  OK: GPU [%d] (%s) -> Screen [%d] (%s)", 
      i, gpuAddrs[i]:sub(1, 12), i, scrAddr:sub(1, 12)))
    print(string.format("     Resolution: %dx%d", w, h))
  else
    print(string.format("  FAIL: GPU [%d] bind failed: %s", i, tostring(err)))
  end
end

print()
print("Setup complete!")
print()
print("If you have 2 GPUs + 2 screens:")
print("  Screen 1 (left)  = Reactor Status (core heat, rods, flux, protection)")
print("  Screen 2 (right) = Energy, LF, Controls, Event Log")
print()
print("Now run: control_client")
print("(The control_client.lua file should be in /home/)")
