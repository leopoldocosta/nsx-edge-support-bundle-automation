# KB404700 — NSX Edge Node: Root Partition & Docker overlay2 Disk Validation

This automation validates whether the root partition (`/dev/sda2`) of NSX Edge Nodes is at 100% capacity and whether `/var/lib/docker/overlay2` is the cause of the disk exhaustion.

## Context

KB404700 addresses scenarios where the Edge Node root partition fills up due to excessive Docker overlay2 data accumulation. This script automates detection across a fleet of Edge Nodes.

## What the script does (per node)

1. **Admin login** — Collects `uptime` and `version`
2. **Admin** — Enables root SSH (`set service ssh root-login enabled`)
3. **Root login** — Runs `df -h` to check if `/dev/sda2` is at 100%
4. **Root login** — Runs `du -xah --time --max-depth=3 /var/lib/docker/` to identify if `overlay2` is the culprit
5. **Admin** — Disables root SSH
6. **Final report** — Prints a consolidated report with verdict per node

## Verdict logic

| Condition | Verdict |
|---|---|
| `/dev/sda2` < 100% AND `overlay2` < 10G | `OK` |
| `/dev/sda2` = 100% OR `overlay2` ≥ 10G | `ACTION REQUIRED` |

> The 10G threshold for `overlay2` is configurable directly in the script (`overlay_num >= 10`).

## Directory structure

```
kb404700_disk_validation/
├── kb404700_disk_validation.sh   # Main script
├── edge_nodes.example            # Template for IP list
└── README.md                     # This file
```

## Prerequisites

- `ssh`, `sshpass`, `awk`, `grep`, `sort` installed on the jump host
- NSX admin credentials with permission to enable/disable root SSH
- Root password for the Edge Nodes

## Usage

```bash
# 1. Enter the automation directory
cd automations/kb404700_disk_validation

# 2. Prepare the IP list
cp edge_nodes.example edge_nodes.txt
vim edge_nodes.txt   # one IP per line

# 3. Run
bash kb404700_disk_validation.sh
```

The script will prompt for **admin** and **root** credentials interactively. Credentials are never written to disk and are cleared from memory at the end.

## Output

- **Console**: real-time log with `[OK]`, `[WARN]`, `[ERR]` prefixes
- **Log file**: `logs/kb404700_run_YYYYMMDD_HHMMSS.log`
- **Report file**: `logs/kb404700_report_YYYYMMDD_HHMMSS.txt`

### Sample report output

```
================================================================================
  KB404700 — NSX Edge Disk Validation Report
  Generated: 2025-06-18 12:00:00
================================================================================

  NODE: 192.168.100.10
  ------------------------------------------------------------------------------
  Uptime:              up 42 days, 3:12
  Version:             NSX 3.2.3.1 Build 21703605

  Partition:           /dev/sda2
    Size:              19G
    Used:              18G
    Avail:             0
    Use%:              100% <-- *** ROOT PARTITION FULL ***

  Docker total:        14G
  overlay2 size:       14G <-- *** overlay2 CAUSING ROOT FULL ***

  VERDICT:             ACTION REQUIRED
  ------------------------------------------------------------------------------
```
