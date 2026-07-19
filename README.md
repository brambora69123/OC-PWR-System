# PWR Reactor Control System v2.2

Two-computer OpenComputers setup for controlling HBMs Nuclear Tech Mod PWR reactors in Minecraft 1.7.10. Monitors turbine speed via Electrical Age probe for load following. Both screens use direct GPU rendering — no external libraries required.

## Architecture

```
[Reactor Computer]                    [Control Room Computer]
  ntm_pwr_control                      GPU1+Screen1 (reactor status, controls)
  ElnProbe (turbine/motor/alarm)       GPU2+Screen2 (turbine, thresholds, log)
  ntm_geiger                           Network Card (wireless modem)
  Redstone (siren)           
  Network Card (wireless modem)  
       |
  Port 7777 (wireless broadcast)
```

Both computers use standard **Network Cards** (wireless). No cables needed.

## File Structure (on each computer)

Everything is installed to `/home/pwr/`:

```
/home/pwr/
  lib/
    protocol.lua         -- Network protocol (message types, serialization)
    reactor_ctrl.lua     -- Reactor control logic (PID, safety, turbine speed LF)
    colors.lua           -- Nuclear theme color palette
    gpu2.lua             -- GPU rendering helper (direct GPU calls)
  reactor_server.lua     -- Server: controls reactor, hosts modem server
  control_client.lua     -- Client: 2-screen display, keyboard controls
  setup_screens.lua      -- One-time GPU/screen binding utility
  install.lua            -- Installer (run this first)
```

## Hardware Requirements

### Reactor Computer
- 1x CPU Tier 3
- 1x RAM Tier 3 (4GB)
- 1x Hard Drive Tier 3
- 1x Network Card (wireless) — **REQUIRED**
- 1x GPU Tier 1 + Screen Tier 1 (for local diagnostics, optional)
- 1x Redstone Card (for siren control, optional)
- 1x ElnProbe (for turbine speed, motor relay, alarm — **RECOMMENDED**)
- Placed adjacent to PWR reactor controller block

### Control Room Computer
- 1x CPU Tier 3
- 1x RAM Tier 3 (4GB)
- 1x Hard Drive Tier 3
- 1x Network Card (wireless) — **REQUIRED**
- **2x GPU Tier 3** — for dual-screen setup
- **2x Screen Tier 3** — for maximum resolution (160x50 each)
- Keyboard

## Setup Instructions

### Step 1: Install Files

On each computer, run:

```
wget https://raw.githubusercontent.com/brambora69123/OC-PWR-System/main/install.lua install.lua
install.lua
```

The installer will:
1. Detect whether this is a reactor or control room PC
2. Download all required files to `/home/pwr/`
3. Optionally set up autorun on boot

### Step 2: Reactor Computer

1. Place the computer next to the PWR reactor controller
2. Place the ElnProbe adjacent to the computer (connect to your shaft network)
3. Configure ELN probe sides in `/home/pwr/lib/reactor_ctrl.lua` (defaultConfig ELN section)
4. Run `reactor_server`
5. The server will:
   - Initialize all reactor components
   - Auto-calibrate on first run (measures heat capacity, tunes PID)
   - Listen for control room connections on port 7777
   - Broadcast telemetry every 0.2s

### Step 3: ELN Probe Configuration

The ElnProbe has 6 sides (XN, XP, YN, YP, ZN, ZP). Configure which side connects to which signal in `/home/pwr/lib/reactor_ctrl.lua`:

```lua
ELN = {
  PROBE_SIDES = {
    TURBINE_SPEED = "ZN",  -- Input: tachometer (0-250 rad/s)
    MOTOR_RELAY   = "ZP",  -- Output: radial motor relay (0/1)
    ALARM         = "YP",  -- Output: alarm signal (0/1)
  },
}
```

Wire the probe sides to your ELN signals:
- **Turbine speed**: Connect a tachometer to a probe input side
- **Motor relay**: Connect a signal relay to a probe output side (controls radial motor + clutch)
- **Alarm**: Connect alarm inputs to a probe output side

### Step 4: Control Room Computer

1. Install 2x GPU Tier 3 and 2x Screen Tier 3
2. Run `setup_screens` once to bind GPUs to screens
3. Run `control_client`

## Display Layout

### Screen 1 (Left) — Reactor Status
- Core/hull heat bars with color-coded thresholds
- Flux, rod position, PID output
- Turbine speed, motor status, alarm status
- Fuel, radiation, coolant levels
- Protection indicators: AZ-1, AZ-2, SCRAM
- Keyboard control reference
- SCRAM banner (flashing)

### Screen 2 (Right) — Turbine / Log
- Turbine speed bar (0-250 rad/s) with optimal range
- Heat target, LF mode
- Configurable thresholds (WARN, AZ-1, AZ-2, SCRAM)
- Scrolling event log (INF/WRN/ERR/CRIT, color-coded)

## Keyboard Controls

| Key | Action |
|-----|--------|
| `S` | Start reactor (IDLE → STARTUP → POWER) |
| `X` | Stop reactor (shutdown gracefully) |
| `R` | SCRAM (emergency) or RESET (clear SCRAM/FAULT) |
| `C` | Force recalibration |
| `1`-`9` | Set power 10%-90% |
| `0` | Set power 100% |
| `Q` | Quit client |

## Safety Systems

| Protection | Action |
|------------|--------|
| Core overheat (96% capacity) | Full SCRAM |
| Hull overheat (95% hull capacity) | Full SCRAM |
| Coolant loss (< 5%) | Full SCRAM |
| Hot tank overflow (> 99%) | Full SCRAM |
| Radiation (> 500 rad/t) | Full SCRAM |
| Telemetry loss | Full SCRAM |
| Turbine fault (won't speed up) | Full SCRAM + alarm |
| High heat (75%) | Warning alarm |
| SCRAM-1 (85%) | Rod insertion + power reduction |
| SCRAM-2 (92%) | Full rod insertion + shutdown |
| Fuel depletion | Graceful shutdown |

## Load Following

Steam is always processed regardless of load. More heat = more steam = more mechanical power capacity. The system adjusts heat target based on turbine speed:

- **Turbine speed low** (high load on shaft): Increase heat target → more steam → more capacity
- **Turbine speed high** (low load on shaft): Decrease heat target → less steam → save fuel
- **Target speed**: 200 rad/s (configurable, optimal range 195-205)
- **Manual mode**: Heat target percentage set directly

## Auto-Calibration

On first run, the reactor server auto-calibrates:
1. Reads reactor heat capacity from NTM API
2. Performs inertia test (brief rod extraction, measures heat rise rate)
3. Calculates PID coefficients tuned to reactor dynamics
4. Saves calibration to `/home/pwr/pwr_cfg.lua`

## Customization

Edit `/home/pwr/lib/reactor_ctrl.lua` (defaultConfig) or `/home/pwr/pwr_cfg.lua`:
- Heat thresholds (or use auto-calibration)
- PID coefficients (auto-tuned on calibration)
- Load following: target speed, deadband, ramp rate, PID gains
- ELN probe sides (turbine speed, motor relay, alarm)
- Turbine parameters: max speed, optimal range, fault thresholds
- Motor start delay
- Redstone side for siren
- Audio on/off

## Troubleshooting

**"Component not found: ntm_pwr_control":**
- Ensure the reactor computer is adjacent to the PWR controller block

**"Component not found: ElnProbe":**
- Ensure the ElnProbe is placed adjacent to the reactor computer
- Check that the Electrical Age mod is installed

**Client can't connect:**
- Both computers need Network Cards (not Wired Network Cards)
- Both must be on the same Minecraft server/world
- Port 7777 must not be used by another mod
- Restart both scripts

**Wrong resolution / blank screen:**
- Run `setup_screens` first
- Both screens must be Tier 3 (160x50 max)
- Both GPUs must be Tier 3

**Autorun not working:**
- Check `/home/.pwr_autorun` exists
- Ensure the file has correct path to your script
- Remove and reinstall: `rm /home/.pwr_autorun`
