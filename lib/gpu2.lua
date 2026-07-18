--[[
  lib/gpu2.lua - GPU Rendering Helper
  Generic GPU renderer that can target any GPU+Screen pair.
  Uses direct component.invoke() calls.
  
  Usage:
    local gpu2 = require("gpu2")
    gpu2.init()           -- auto-detect second GPU
    gpu2.clear()
    gpu2.text(1, 1, color, "Hello")
    gpu2.rect(1, 2, 40, 1, bgColor)
    gpu2.bar(1, 3, 20, 75, 100, activeColor, passiveColor)
]]

local component = require("component")

local gpu2 = {
  gpu     = nil,
  addr    = nil,
  w       = 80,
  h       = 25,
  ready   = false,
}

function gpu2.init(usePrimary)
  local target = nil
  if usePrimary then
    target = component.gpu
  else
    local primaryAddr = component.gpu and component.gpu.getScreen() or nil
    for addr in component.list("gpu") do
      if addr ~= primaryAddr then
        target = component.proxy(addr)
        break
      end
    end
    if not target then target = component.gpu end
  end

  if not target then return 0, 0 end

  gpu2.gpu = target
  gpu2.addr = target.address
  local maxW, maxH = target.maxResolution()
  target.setResolution(maxW, maxH)
  gpu2.w, gpu2.h = target.getResolution()
  gpu2.ready = true
  return gpu2.w, gpu2.h
end

function gpu2.fg(color)
  if gpu2.gpu then pcall(gpu2.gpu.setForeground, color) end
end

function gpu2.bg(color)
  if gpu2.gpu then pcall(gpu2.gpu.setBackground, color) end
end

function gpu2.colors(fg, bg)
  if gpu2.gpu then
    if fg then pcall(gpu2.gpu.setForeground, fg) end
    if bg then pcall(gpu2.gpu.setBackground, bg) end
  end
end

function gpu2.text(x, y, color, str)
  if gpu2.gpu and str then
    if color then pcall(gpu2.gpu.setForeground, color) end
    pcall(gpu2.gpu.set, x, y, tostring(str))
  end
end

function gpu2.rect(x, y, w, h, bgColor, char)
  if gpu2.gpu then
    if bgColor then pcall(gpu2.gpu.setBackground, bgColor) end
    pcall(gpu2.gpu.fill, x, y, w, h or 1, char or " ")
  end
end

function gpu2.bar(x, y, w, value, maxVal, activeColor, passiveColor)
  local n = math.floor(math.max(0, math.min(100, value / math.max(maxVal, 1) * 100)) / 100 * w)
  gpu2.colors(activeColor, passiveColor)
  if gpu2.gpu then
    pcall(gpu2.gpu.set, x, y, string.rep("#", n))
    pcall(gpu2.gpu.set, x + n, y, string.rep(".", w - n))
  end
end

function gpu2.clear(bgColor)
  if gpu2.gpu then
    if bgColor then pcall(gpu2.gpu.setBackground, bgColor) end
    pcall(gpu2.gpu.fill, 1, 1, gpu2.w, gpu2.h, " ")
  end
end

function gpu2.clearRegion(x, y, w, h, bgColor)
  if gpu2.gpu then
    if bgColor then pcall(gpu2.gpu.setBackground, bgColor) end
    pcall(gpu2.gpu.fill, x, y, w, h, " ")
  end
end

function gpu2.present()
end

return gpu2
