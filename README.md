# sysadmin-toolbox

Production-ready PowerShell scripts and tools for Windows Server administration, infrastructure migrations, and IT automation.

This repository is a growing collection of generalised, publicly available PowerShell scripts written for day-to-day sysadmin work. Scripts are organised by the Windows Server role or functional area they target, so you can find what you need quickly and drop new contributions into the right place.

## Repository structure

```
sysadmin-toolbox/
├── Scripts/              # All standalone PowerShell scripts, grouped by role/area
│   ├── ActiveDirectory/  # AD DS, users, groups, GPOs, domain operations
│   ├── DHCP/             # DHCP server configuration, scopes, failover, migration
│   ├── DNS/              # DNS server zones, records, forwarders
│   ├── Exchange/         # Exchange Server / hybrid administration
│   ├── FileServices/     # File server, SMB shares, DFS, permissions
│   ├── HyperV/           # Hyper-V hosts, VMs, virtual switches
│   ├── Monitoring/       # Health checks, reporting, alerting
│   ├── Networking/       # General networking, routing, firewall
│   ├── Security/         # Auditing, hardening, certificates
│   └── Utilities/        # General-purpose helpers that don't fit elsewhere
├── Modules/              # Reusable PowerShell modules (.psm1 / .psd1)
└── Docs/                 # Extended documentation, usage guides, examples
```

## Conventions

- **File naming:** Use approved PowerShell verbs and `Verb-Noun.ps1` format (e.g. `Migrate-DHCPFailover.ps1`, `Get-ADUserReport.ps1`).
- **Comment-based help:** Every script should include a `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, and `.EXAMPLE` block so `Get-Help` works out of the box.
- **Parameters:** Prefer `[CmdletBinding()]` with typed, named parameters over positional arguments.
- **Placement:** Drop new scripts into the folder matching their primary Windows role or functional area. If nothing fits, use `Scripts/Utilities/`.

## Usage

Scripts are standalone — clone the repo (or download the individual `.ps1` file) and run from an elevated PowerShell session on a machine with the relevant RSAT / role tools installed.

```powershell
git clone https://github.com/marcustedde/sysadmin-toolbox.git
cd sysadmin-toolbox\Scripts\DHCP
.\Migrate-DHCPFailover.ps1 -WhatIf
```

Always review a script and run with `-WhatIf` (where supported) before executing against production.

## Disclaimer

These scripts are provided as-is, without warranty. Test in a lab or non-production environment first. You are responsible for any changes they make to your systems.
