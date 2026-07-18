--[[
  lib/colors.lua - Nuclear Control Room Color Theme
  Shared GUI color constants for both server diagnostics and client UI.
]]

return {
  BG        = 0x000D1F,
  PANEL     = 0x0A1628,
  PANEL2    = 0x061020,
  BORDER    = 0x0D3D6B,
  BORDER2   = 0x1A5896,
  TEXT      = 0x8ABFDE,
  TEXT2     = 0x5A8AAB,
  HEADER    = 0x00D4FF,
  HEADER2   = 0x007799,
  GREEN     = 0x00FF80,
  GREEN2    = 0x00AA44,
  YELLOW    = 0xFFCC00,
  GOLD      = 0xFFAA00,
  ORANGE    = 0xFF7700,
  RED       = 0xFF1A1A,
  RED2      = 0xCC0000,
  DKRED     = 0x440000,
  PINK      = 0xFF55BB,
  BLUE      = 0x2299FF,
  CYAN      = 0x00AACC,
  TEAL      = 0x00CC99,
  WHITE     = 0xFFFFFF,
  GRAY      = 0x334455,
  GRAY2     = 0x1A2A3A,
  DGRAY     = 0x0A1520,

  -- Mode colors
  MODE = {
    INIT       = 0x334455,
    IDLE       = 0x00AACC,
    STARTUP    = 0x2299FF,
    POWER      = 0x00FF80,
    SHUTDOWN   = 0xFFCC00,
    SCRAM      = 0xFF1A1A,
    FAULT      = 0xFF1A1A,
    CALIBRATE  = 0xAA44FF,
  },
}
