--[[
  lib/gpu2.lua - Second GPU Rendering Helper
  Manages a secondary GPU+Screen pair for the control room's Screen 2.
  Uses direct component.invoke() calls so it doesn't interfere with
  the primary GPU used by doubleBuffering / GUI library.
  
  Usage:
    local gpu2 = require("gpu2")
    gpu2.init()           -- auto-detect and bind second GPU
    gpu2.clear()
    gpu2.text(1, 1, color, "Hello")
    gpu2.rect(1, 2, 40, 1, bgColor)
    gpu2.bar(1, 3, 20, 75, 100, activeColor, passiveColor)
    gpu2.present()        -- flush (no-op for direct GPU, but keeps API consistent)
]]

local component = require("component")

local gpu2 = {
  gpu     = nil,    -- proxy to second GPU
  addr    = nil,    -- address string
  w       = 80,     -- current width
  h       = 25,     -- current height
  ready   = false,
}

-- Find and bind the second GPU (the one that is NOT the primary)
function gpu2.init()
  local primary = component.gpu
  local primaryAddr = primary and primary.getScreen() or nil

  local candidates = {}
  for addr in component.list("gpu") do
    if addr ~= (primary and primary.address or nil) then
      table.insert(candidates, addr)
    end
  end

  if #candidates == 0 then
    -- Fallback: use primary GPU but in a separate "virtual" mode
    -- This handles single-GPU setups gracefully
    gpu2.gpu = primary
    gpu2.addr = primary and primary.address or "none"
  else
    gpu2.gpu = component.proxy(candidates[1])
    gpu2.addr = candidates[1]
  end

  -- Set max resolution
  local maxW, maxH = gpu2.gpu.maxResolution()
  gpu2.gpu.setResolution(maxW, maxH)
  gpu2.w, gpu2.h = gpu2.gpu.getResolution()
  gpu2.ready = true

  return gpu2.w, gpu2.h
end

-- Set foreground color
function gpu2.fg(color)
  if gpu2.gpu then pcall(gpu2.gpu.setForeground, color) end
end

-- Set background color
function gpu2.bg(color)
  if gpu2.gpu then pcall(gpu2.gpu.setBackground, color) end
end

-- Set colors at once
function gpu2.colors(fg, bg)
  if gpu2.gpu then
    if fg then pcall(gpu2.gpu.setForeground, fg) end
    if bg then pcall(gpu2.gpu.setBackground, bg) end
  end
end

-- Draw text at position
function gpu2.text(x, y, color, str)
  if gpu2.gpu and str then
    if color then pcall(gpu2.gpu.setForeground, color) end
    pcall(gpu2.gpu.set, x, y, tostring(str))
  end
end

-- Draw filled rectangle
function gpu2.rect(x, y, w, h, bgColor, char)
  if gpu2.gpu then
    if bgColor then pcall(gpu2.gpu.setBackground, bgColor) end
    pcall(gpu2.gpu.fill, x, y, w, h or 1, char or " ")
  end
end

-- Draw a progress bar
function gpu2.bar(x, y, w, value, maxVal, activeColor, passiveColor)
  local n = math.floor(math.max(0, math.min(100, value / math.max(maxVal, 1) * 100)) / 100 * w)
  gpu2.colors(activeColor, passiveColor)
  if gpu2.gpu then
    pcall(gpu2.gpu.set, x, y, string.rep("#", n))
    pcall(gpu2.gpu.set, x + n, y, string.rep(".", w - n))
  end
end

-- Clear entire screen
function gpu2.clear(bgColor)
  if gpu2.gpu then
    if bgColor then pcall(gpu2.gpu.setBackground, bgColor) end
    pcall(gpu2.gpu.fill, 1, 1, gpu2.w, gpu2.h, " ")
  end
end

-- Clear a specific region
function gpu2.clearRegion(x, y, w, h, bgColor)
  if gpu2.gpu then
    if bgColor then pcall(gpu2.gpu.setBackground, bgColor) end
    pcall(gpu2.gpu.fill, x, y, w, h, " ")
  end
end

-- Flush / present (direct GPU doesn't need this, but keeps API compatible)
function gpu2.present()
  -- No-op for direct GPU calls
end

return gpu2
