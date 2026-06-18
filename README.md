# OV-Audit — Windows Server Licensing Inventory

A **read-only**, hypervisor-agnostic PowerShell tool that inventories a Windows
Server estate and produces the data needed to right-size a licensing renewal
(built originally for an **Open Value** renewal, but the raw inventory feeds any
vehicle — EA/MCA-E, CSP, SPLA, Open).

The goal is the **cheapest-compliant** licensing position: it captures the data
that actually drives cost — **physical-host core counts, socket counts, and
VM density per host** — not just a flat list of machines.

> ⚠️ **Read-only by design.** OV-Audit only *reads* inventory data (WMI/CIM
> queries, AD lookups, hypervisor API reads). It never writes, changes, or
> restarts anything in the environment.

## What it collects

| Area | Fields |
|---|---|
| **Identity** | Hostname, FQDN, IP(s), domain, last boot, OS install date |
| **OS / edition** | Caption, version, build, architecture, **Standard vs Datacenter** |
| **CPU (licensing core)** | **Physical socket count**, cores/socket, **total physical cores**, logical processors |
| **Virtualization** | Physical vs virtual, hypervisor type, **VM ↔ physical-host mapping** |
| **SQL Server** | Instances, edition, version (a major secondary cost driver) |
| **Roles** | RDS and other licensable roles/features installed |
| **CAL footprint** | Enabled AD user / device counts to size Server + RDS CALs |

## Why "pull from existing sources"

A guest VM can report its **vCPU** count but **cannot see the physical host's
cores** — and Windows Server is licensed on *physical host cores*. So OV-Audit
gets host core counts straight from the hypervisor:

- **VMware** — via PowerCLI (`Get-VMHost`, `Get-VM`)
- **Hyper-V** — via `Get-VMHost` / failover-cluster cmdlets
- **Nutanix AHV** — via the Prism Element REST API (`/hosts`, `/vms`)
- **Physical / other** — directly via CIM on the host
- **SCCM/MECM** — optional supplement if present

Per-guest detail (OS, SQL, roles) is collected via CIM where reachable.

## Requirements

- PowerShell 5.1+ (Windows) or 7.x. Run from a domain-joined admin workstation / jump box.
- **RSAT ActiveDirectory** module (for the AD server list + CAL counts).
- **VMware PowerCLI** (`Install-Module VMware.PowerCLI`) if VMware is present.
- **Hyper-V / FailoverClusters** modules if Hyper-V is present.
- For **Nutanix AHV**: network access to each Prism Element on TCP 9440 and a read-only Prism account. No extra PowerShell module is needed (it uses `Invoke-RestMethod`). **Run from PowerShell 7** for Nutanix (5.1's TLS stack can fail the handshake to recent AOS). If you don't know the cluster VIPs, set `Nutanix.Subnet` in the config and the audit **auto-discovers the Prism Element clusters** on that subnet (skipping Prism Central); or run `tools/Find-OVPrism.ps1 -Subnet <first-3-octets>` to find them yourself.
- For **Azure / Arc discovery** (optional): `Az.Accounts` + `Az.ResourceGraph` modules and a read-only **Reader** role at the management-group or subscription scope.
- Credentials with read access to: AD, the hypervisor management plane(s), and the target servers (WinRM preferred, DCOM/WMI fallback).

## Getting the tool

### Option A — clone with Git (recommended)

Cloning avoids the "Mark-of-the-Web" prompt entirely (git-written files aren't
tagged as internet-downloaded, so there's no `Unblock-File` step), and updates are
one command (`git pull`).

```powershell
# Needs Git installed:  winget install Git.Git
git clone https://github.com/rpmcds12/OV_Audit.git
cd OV_Audit
.\tools\Test-OVPrereqs.ps1 -ConfigPath .\config.psd1   # after you create config.psd1 (see Usage)

# later, to get the latest version:
git pull
```

The repo is **private**, so the machine has to authenticate to GitHub. Pick one:

- **GitHub CLI (easiest):** `winget install GitHub.cli`, then `gh auth login`, then
  `gh repo clone rpmcds12/OV_Audit`
- **Personal Access Token (PAT):** `git clone https://<PAT>@github.com/rpmcds12/OV_Audit.git`
- **SSH key:** `git clone git@github.com:rpmcds12/OV_Audit.git`

Then skip step 0 below (no Mark-of-the-Web on cloned files) and go straight to the config + run.

### Option B — download the ZIP

Repo page → **Code → Download ZIP** (or `https://github.com/rpmcds12/OV_Audit/archive/refs/heads/main.zip`),
extract, and **clear the internet block first** (Usage step 0). Use this when the
jump box has no Git or can't authenticate to GitHub.

## Usage

```powershell
# 0. ZIP DOWNLOAD ONLY — clear the internet "Mark-of-the-Web" (skip if you used git clone),
#    or PowerShell prompts before every script and a module that gets a "Do not run" answer fails.
Get-ChildItem -Recurse -File | Unblock-File

# 1. Copy and edit the config
Copy-Item .\config.example.psd1 .\config.psd1
notepad .\config.psd1   # set your vCenter(s), Hyper-V hosts, AD scope, output path

# 1b. Pre-flight: verify prerequisites + connectivity (read-only, PASS/WARN/FAIL)
.\tools\Test-OVPrereqs.ps1 -ConfigPath .\config.psd1

# 2. Run the audit (read-only)
.\Invoke-OVAudit.ps1 -ConfigPath .\config.psd1

# Output lands in .\output\ :
#   inventory.csv / inventory.json        — raw per-server data
#   host-summary.csv                      — physical hosts with core counts + VM density
#   discovery-coverage.csv                — every server, how it was found, and what is NOT in AD
#   OV-Audit-Report.xlsx                  — detailed workbook (recommended license position)
#   OV-Audit-Executive-Summary.pdf/.doc   — customer-facing summary deliverable
```

> **New to running it, or doing it on a customer site?** Follow the step-by-step
> operator guide in **[RUNSHEET.md](RUNSHEET.md)** — it walks through the jump-box
> build, which sources to enable, accounts and minimum (read-only) rights,
> firewall ports, pre-flight checks, a field-by-field config walkthrough, how to
> read each output file, and troubleshooting for every issue seen in the field.
> Run from **PowerShell 7** (`pwsh`) when Nutanix or Azure is in scope.

## Sources

| Source | Used for | Notes |
|---|---|---|
| **Active Directory** | Server list + CAL footprint | `Get-ADComputer` filtered to server OSes |
| **VMware (PowerCLI)** | Physical host cores + VM↔host map | host cores from `CpuInfo.NumCpuCores` (physical, not logical) |
| **Hyper-V** | Physical host cores + VM↔host map | host cores via CIM on the host |
| **Nutanix AHV** | Physical host cores + VM↔host map + guest OS | Prism Element REST v2.0 (`num_cpu_cores`); VM virtual cores = `num_vcpus × num_cores_per_vcpu`; guest OS from NGT (`nutanix_guest_tools.guest_os_version`) where installed, which classifies VMs without CIM. No extra module needed. |
| **SCCM/MECM** *(optional)* | Breadth + **offline backfill** | Fills OS/core data for servers that couldn't be reached live. Its agent reports *guest* vCPUs on a VM, so it never overrides hypervisor host-core truth — used for physical/unreachable boxes only. |
| **Azure Resource Graph** *(optional)* | Catch servers **not in on-prem AD** | Arc-enabled servers (on-prem/other-cloud, with detected physical cores) + native Azure VMs. Needs `Az.Accounts`/`Az.ResourceGraph` and a read-only **Reader** role. Discover-and-report (listed in the coverage report; not yet folded into the cost engine). |
| **Local collector** *(optional)* | OS / cores / SQL / roles when **remoting is blocked** | `tools/Collect-OVLocal.ps1` runs read-only on each server (deploy via NinjaOne / GPO / Intune), drops `<hostname>.json` to a share; the `LocalDrop` config source ingests it. No inbound remoting at all. |

### Discovery and the "not in AD" gap

AD only lists domain-joined machines. As estates move to Entra-only / hybrid, that
under-counts. OV-Audit reconciles **all** sources (AD + every hypervisor's VM list +
SCCM + Azure/Arc) into one de-duplicated target set, scans each server, and writes
**`discovery-coverage.csv`** tagging every server with how it was found and whether
it is in AD. Hypervisor VM enumeration already catches non-domain-joined VMs for
free; Azure Resource Graph catches the cloud-resident ones. (Servers in *no*
directory at all still need a network/DNS sweep, a planned future source.)

## Status

- [x] Project scaffold, config, README
- [x] Per-server CIM collector (OS / cores / sockets / virtualization detection) — `src/OVAudit.Collect.psm1`
- [x] AD server enumeration + CAL footprint — `src/OVAudit.Sources.psm1`
- [x] VMware (PowerCLI) host + VM-mapping collector — `src/OVAudit.Sources.psm1`
- [x] Hyper-V host + VM-mapping collector — `src/OVAudit.Sources.psm1`
- [x] Nutanix AHV (Prism REST v2.0) host + VM-mapping collector — `src/OVAudit.Sources.psm1`
- [x] SCCM/MECM source + offline backfill — `src/OVAudit.Sources.psm1`
- [x] Azure Resource Graph source (Arc + Azure VMs), discover-and-report — `src/OVAudit.Sources.psm1`
- [x] Non-AD discovery reconciliation + `discovery-coverage.csv` — `Invoke-OVAudit.ps1`
- [x] SQL Server detection (StdRegProv, transport-agnostic) — `src/OVAudit.Collect.psm1`
- [x] Orchestrator that joins guest detail to host mapping — `Invoke-OVAudit.ps1`
- [x] License-position engine (Standard-vs-Datacenter-vs-per-VM, core minimums, SA rights) — `src/OVAudit.License.psm1`
- [x] Detailed report export (Excel via ImportExcel, HTML fallback) — `src/OVAudit.Report.psm1`
- [x] Customer-facing executive summary (PDF + Word + HTML) — `src/OVAudit.ExecSummary.psm1`
- [x] Licensing-math + collectors + report test suite (71 cases, all passing) — `tests/Test-OVLicense.ps1`
- [x] Pre-flight checker (prereqs + connectivity, PASS/WARN/FAIL) — `tools/Test-OVPrereqs.ps1`
- [x] Local collector + drop ingest for WinRM-blocked estates — `tools/Collect-OVLocal.ps1`
- [x] Partial-failure resilience (per-source try/catch, checkpoint export) + a Coverage section that gates the "no data gaps" claim — `Invoke-OVAudit.ps1`, `src/OVAudit.ExecSummary.psm1`
- [ ] Network / DNS sweep for servers in no directory at all *(planned)*
- [ ] Fold cloud servers into the cost engine (Azure Hybrid Benefit vs physical) *(planned)*

## How the recommendation is computed

For every **physical host** (hypervisor host or standalone physical server) the
engine computes `LicensableCores = MAX(16, Σ MAX(8, coresPerSocket))` (rounded up
to a 2-core pack) and compares the three **compliant** ways to cover the Windows
Server guests on it, then picks the cheapest:

1. **Datacenter** — all host cores, unlimited Windows VMs.
2. **Stacked Standard** — `ceil(VMs / 2) × LicensableCores`.
3. **Per-VM (vCore)** — `Σ MAX(8, vCPUs)`; **only offered if Software Assurance
   / subscription is present** (Open Value typically qualifies).

It **forces Datacenter** when a host requires it: **Storage Spaces Direct (S2D)**
is auto-detected on Hyper-V failover clusters (via the cluster's `S2DEnabled`
state) and stamped on those hosts, and any HA-clustered host without SA is forced
(the 90-day reassignment rule means every potential target node must be licensed).
Other Datacenter-only features (SDN/Network Controller, guarded Hyper-V host,
Storage Replica beyond Standard's limit) are **not yet auto-detected** — confirm
those manually for now. The per-host **break-even VM count** is reported so the
Standard-vs-Datacenter call is transparent.

A VM whose OS can't be determined (no CIM, not in AD, no NGT/guest OS) is counted
as **Unknown**, not silently as non-Windows: it's excluded with a per-host warning
and an `UnknownVMCount` column (set `UnknownVmTreatment = 'AssumeWindows'` to count
them instead). The executive summary's **Coverage** section flags any of this and
only claims "no data gaps" when coverage is genuinely complete.

With Software Assurance present (the Open Value case), **per-VM can beat
Datacenter even on a fairly dense host** when the VMs have low vCPU counts, since
per-VM cost scales with `Σ MAX(8, vCPUs)` rather than the host's full core count.
The engine reports the cheapest option; the per-host Datacenter figure is always
shown alongside it.

**Operational-simplicity override.** If you would rather not manage per-VM
counting on busy hosts, set `PreferDatacenterAtVMCount` in `config.psd1` to a VM
threshold (e.g. `8`). Any host at or above it is recommended Datacenter even when
a cheaper option exists. The report still records the lowest-cost option
(`CheapestModel` / `CheapestCost`) and the `OperationalPremium` that choice costs,
so the trade-off stays explicit. Leave it at `0` to always take the cheapest.
Compliance-forced Datacenter (features / no-SA clustering) is separate and is not
counted as a preference premium.

Run the tests: `pwsh ./tests/Test-OVLicense.ps1`

## The customer deliverable

`OVAudit.ExecSummary.psm1` produces a plain-English executive summary in three
formats so it works anywhere and is easy to rebrand:

- **`.pdf`** — rendered with headless Edge or Chrome (present on essentially all
  Windows servers/clients, no install needed). Skips cleanly if neither is found.
- **`.doc`** — opens directly in Word for editing/rebranding; no Office or extra
  module required to generate it.
- **`.html`** — print-ready fallback.

It leads with the recommended position, the **estimated savings versus licensing
Datacenter on every host**, the model mix, the cost drivers, and the data gaps.
Set `CustomerName` / `PreparedBy` in `config.psd1`.

## Optional dependencies

- **`ImportExcel`** (`Install-Module ImportExcel`) — for the multi-sheet `.xlsx`
  workbook. Without it, the detailed report falls back to styled HTML.
- **Microsoft Edge or Google Chrome** — for PDF generation. Without it, open the
  `.html`/`.doc` and export to PDF manually.

> ⚠️ **Estimates, not a quote.** Default prices are Microsoft *suggested list*.
> Override `StandardPerCore` / `DatacenterPerCore` in `config.psd1` with the
> customer's actual Open Value pricing, and validate the final position against
> the live Microsoft Product Terms at quote time.
