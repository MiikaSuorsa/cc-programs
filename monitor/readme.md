# CC:Tweaked Programs

A collection of programs for CC:Tweaked computers in modded Minecraft.

## Monitor

A multi-computer monitoring system that tracks energy storage, ME system items, inventories(eg. chests, drawers) and fluid tanks with real-time graphs and alerts.

### Architecture

| Computer | Program | Role |
|----------|---------|------|
| Sensor | `sensor.lua` | Reads a peripheral and broadcasts data via rednet |
| Data Server | `dataserver.lua` | Receives all sensor data, stores history to disk, serves queries |
| Display | `display.lua` | Shows live data, graphs, and alerts on a monitor |

Deploy one sensor per peripheral, one data server, and as many displays as you want. All communicate over rednet.

### Features

- Energy, item, and fluid monitoring
- Supports RF/FE blocks, AE2 ME systems, regular inventories, and tanks
- Line graphs with configurable time spans (1 minute to 30 days)
- Touch-to-inspect graph values on advanced monitors
- Tiered data storage with automatic downsampling (per-second → per-minute → hourly → daily)
- Data persists across server restarts
- Configurable alerts with flashing panels and analog redstone output
- Single-view and multi-panel dashboard layouts
- Noise reduction and smoothing for stable graphs

### Installation

HTTP must be enabled in the CC:Tweaked config.

On each computer, run the appropriate wget command. Replace `<version>` with your Minecraft version (e.g. `1.12.2`, `1.20.1`):

**Sensor:**
```
wget https://raw.githubusercontent.com/MiikaSuorsa/cc-programs/main/monitor/<version>/sensor.lua sensor
```

**Data Server:**
```
wget https://raw.githubusercontent.com/MiikaSuorsa/cc-programs/main/monitor/<version>/dataserver.lua dataserver
```

**Display:**
```
wget https://raw.githubusercontent.com/MiikaSuorsa/cc-programs/main/monitor/<version>/display.lua display
```

After downloading, edit the config section at the top of each file to match your setup (modem side, peripheral side, tracked items, etc.), then run the program by typing its name.

### Setup Order

1. Start the data server first
2. Start sensors — they begin broadcasting immediately
3. Start displays — they discover sensors and the data server automatically

See the version-specific README in each folder for ready-to-paste commands.

## License

MIT