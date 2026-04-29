# Energy Monitor - MC 1.12.2

CC:Tweaked 1.89.2 — Forge 1.12.2

## Installation

Paste the command for the program you need on the target computer:

**Sensor** (computer next to the peripheral):
```
wget https://raw.githubusercontent.com/MiikaSuorsa/cc-programs/main/monitor/1.12.2/sensor.lua sensor
```

**Data Server** (dedicated computer):
```
wget https://raw.githubusercontent.com/MiikaSuorsa/cc-programs/main/monitor/1.12.2/dataserver.lua dataserver
```

**Display** (computer with monitor):
```
wget https://raw.githubusercontent.com/MiikaSuorsa/cc-programs/main/monitor/1.12.2/display.lua display
```

Edit the config at the top of each file, then run by typing the program name.

## Peripheral Methods

This version uses the following methods:

| Source | Methods |
|--------|---------|
| Energy blocks | `getEnergyStored()`, `getEnergyCapacity()` |
| ME network energy | `getNetworkEnergyStored()`, `getNetworkEnergyUsage()` |
| ME items | `listAvailableItems()` |
| Inventories | `list()` |
| Tanks | `getTanks()` |