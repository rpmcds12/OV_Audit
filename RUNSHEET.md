# OV-Audit Run Sheet (operator guide)

A step-by-step guide to running the audit on-site, written so you can follow it
cold. **Everything OV-Audit does is read-only.** It only *queries* inventory
(Active Directory lookups, hypervisor API reads, Azure Resource Graph reads,
WMI/CIM reads). It never writes, changes, installs, or restarts anything in the
environment.

### What it does, in one paragraph

OV-Audit builds the list of Windows Servers from every source it can reach
(Active Directory, the hypervisors, SCCM, and Azure/Arc), gets the **physical
host core counts** straight from each hypervisor (because that, not guest vCPUs,
is what Windows Server is licensed on), reads OS edition / SQL / roles from each
server over CIM, then calculates the **cheapest compliant** licensing position
and writes both raw data and a customer-facing summary.

### The order it runs in

1. Active Directory → the baseline server list + CAL counts
2. Each enabled hypervisor → physical host cores + which VM runs on which host
3. Azure / Arc (if enabled) → servers that live in the cloud / left on-prem AD
4. SCCM (if enabled) → fills gaps and backfills servers it couldn't reach live
5. Per-server CIM sweep → OS edition, cores, SQL, roles
6. License engine → cheapest compliant position per host
7. Reports → CSV/JSON, an Excel/HTML workbook, and a PDF/Word executive summary

---

## 1. Where to run it

Run it from a **domain-joined admin workstation or a member-server jump box**.
**Do not run it on a domain controller.** A DC is a tier-0 asset; you don't want
to install extra modules on it or type hypervisor/server admin credentials into a
session on it. The DC is something OV-Audit *queries* over the network, not where
it executes.

The machine you run it from needs network access and credentials to each source
you turn on (covered in sections 4 and 5).

---

## 2. Build the jump box

Install only what matches the sources at this site.

| Need | Install / check | Required when |
|---|---|---|
| **PowerShell 7** (`pwsh`) | `winget install Microsoft.PowerShell` | strongly recommended always; **required for Nutanix and Azure** |
| Windows PowerShell 5.1 | built in | works for AD/VMware/Hyper-V/SCCM only |
| **RSAT ActiveDirectory** | `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` | always (server list + CALs) |
| **VMware PowerCLI** | `Install-Module VMware.PowerCLI -Scope CurrentUser` | VMware present |
| **Hyper-V + FailoverClusters** modules | `Add-WindowsCapability` / RSAT | Hyper-V present |
| **Nutanix** | nothing to install (uses `Invoke-RestMethod`) | AHV present |
| **Az.Accounts + Az.ResourceGraph** | `Install-Module Az.Accounts, Az.ResourceGraph -Scope CurrentUser` | Azure / Arc discovery |
| **ImportExcel** | `Install-Module ImportExcel -Scope CurrentUser` | optional, for the `.xlsx` workbook (HTML is written if absent) |
| **Microsoft Edge or Chrome** | already on most Windows | optional, for the PDF summary |

### Why PowerShell 7

Run with `pwsh` whenever **Nutanix or Azure** is in scope. Windows PowerShell
5.1's older TLS stack can fail the HTTPS handshake to recent Nutanix Prism/AOS
(you'll see *"SSL connection could not be established"* or *"unexpected error on
a send"*), and the Az modules are happier on 7. PowerShell 7 also runs the
per-server CIM sweep in parallel, so large estates finish much faster. AD,
VMware, Hyper-V, and SCCM all work on 5.1 too, but there's no downside to just
using 7 for everything.

### Clear the internet block if you downloaded this

If you got OV-Audit as a **GitHub ZIP** (or any browser download), Windows tags
every file as "from the internet" (Mark-of-the-Web). PowerShell then prompts
*"Do you want to run..."* before each script, and if any one gets a "Do not run"
answer the run dies with *"...cannot be loaded because you opted not to run this
software now."* Clear it once, from inside the project folder:

```powershell
Get-ChildItem -Recurse -File | Unblock-File           # strip the internet tag from all files
Set-ExecutionPolicy -Scope Process Bypass -Force      # no script prompts for this session only
```

---

## 3. Decide which sources to enable

Every site uses **Active Directory** (the baseline). Then turn on what's actually
there:

- **Hypervisor** — enable the one(s) in use (`VMware`, `HyperV`, `Nutanix`). This
  is where the physical host core counts come from, so it matters most.
- **Azure** — enable if the customer has an Azure footprint or Arc-connected
  servers. This catches Windows Servers that are **not in on-prem AD** (the
  Entra-only / cloud trend). It is discover-and-report: those servers appear in
  the coverage report but are not yet priced into the cost engine.
- **SCCM/MECM** — enable if they run it; it adds breadth and lets the tool
  backfill servers it couldn't reach live.

You enable each by setting `Enabled = $true` in its block in `config.psd1`
(section 7). Leaving a source `$false` simply skips it.

---

## 4. Accounts and minimum rights

Use dedicated **read-only** accounts. Do not use Domain Admin. Keep the
server-admin rights in a tier-1 group, separate from any tier-0 (DC) accounts.

| Source | Minimum rights (read-only) | Why this is enough |
|---|---|---|
| **Active Directory** | Any authenticated domain user | Reading computer/user objects needs no elevation |
| **Target servers (CIM)** | Local Administrator on the targets | WMI `root\cimv2` and `Get-WindowsFeature` require local admin; add a dedicated domain group to local Administrators on member servers |
| **VMware vCenter** | Built-in **Read-only** role at the vCenter root, propagated | Read-only can enumerate hosts/VMs but change nothing |
| **Hyper-V hosts** | **Hyper-V Administrators** (or local admin) on each host; cluster read | Reading host CPU + the VM list needs host access |
| **Nutanix Prism** | A **Viewer** (read-only) Prism account | GET on `/hosts`, `/vms`, `/cluster` is all the tool does |
| **Azure / Arc** | Built-in **Reader** role at the management-group (or subscription) scope | Reader covers Resource Graph + Arc/VM reads; never use Contributor/Owner or any onboarding role |
| **SCCM/MECM** | **Read-only Analyst** role + remote WMI to the SMS Provider | Reads the hardware-inventory classes only |

---

## 5. Firewall ports (jump box → source)

| Source | Ports |
|---|---|
| AD PowerShell module (ADWS) | **TCP 9389** to a DC, plus Kerberos 88 / DNS 53 for auth and name resolution |
| Per-server detail via WinRM | **TCP 5985** (HTTP) / **5986** (HTTPS) to each target |
| Per-server detail via DCOM/WMI fallback | **TCP 135** + the dynamic RPC range **49152–65535** |
| VMware vCenter / ESXi | **TCP 443** |
| Nutanix Prism Element | **TCP 9440** (to the CVM IPs and the cluster VIP — *not* the AHV host IP) |
| Azure / Arc | **TCP 443** outbound to `login.microsoftonline.com` and `management.azure.com` |
| SCCM SMS Provider (WMI) | **TCP 135** + dynamic RPC **49152–65535** |

> If the jump box is behind **Global Secure Access** / a network-access client,
> sign into it first or these calls will fail at the network layer.

---

## 6. Pre-flight (prove each source is reachable before the full run)

Run these for the sources you enabled. Each should return data, not an error.

```powershell
# Active Directory (uses ADWS on 9389)
Get-ADDomain | Select-Object DNSRoot

# A sample target over WinRM, then the DCOM port as a fallback check
Test-WSMan SERVER01
Test-NetConnection SERVER01 -Port 135

# VMware
Test-NetConnection VCENTER01 -Port 443

# SCCM SMS Provider
Get-CimInstance -ComputerName CM01 -Namespace root\sms -ClassName SMS_ProviderLocation

# Azure (run in pwsh; confirms login + Resource Graph access)
Connect-AzAccount
Search-AzGraph -Query "Resources | limit 1" -UseTenantScope
```

### Nutanix: find the Prism VIP first

Prism does **not** run on the AHV host IP. It runs on the **CVM IPs and the
cluster VIP** (TCP 9440). Use the bundled helper to find the VIP(s) to put in the
config. Give it the first three octets of any CVM/host IP on that subnet, and run
it from **PowerShell 7**:

```powershell
pwsh ./tools/Find-OVPrism.ps1 -Subnet 198.18.244
```

It scans for 9440, asks each responder which cluster it is, and prints the
distinct clusters with a ready-to-paste `Prisms = @(...)` line. Use the **VIP**
per cluster. If different clusters use different local Prism accounts, run it once
per credential set with `-Credential (Get-Credential)`.

---

## 7. Fill in the config

```powershell
Copy-Item .\config.example.psd1 .\config.psd1
notepad .\config.psd1
```

It's a PowerShell data file, so: booleans are `$true` / `$false` (with the `$`),
lists are `@('a','b')`, and strings need quotes. A stray comma or missing quote
makes the whole file fail to load.

Work through it top to bottom:

- **`Report.CustomerName`** — the customer's name; it prints on the executive
  summary. Set `PreparedBy` too (defaults to `US Signal`).
- **`ActiveDirectory`** — leave `Enabled = $true`. Leave `Server`/`SearchBase`
  as `$null` to use the current domain, or set `SearchBase` to scope to one OU,
  e.g. `'OU=Servers,DC=contoso,DC=com'`.
- **The hypervisor block(s) you have** — set `Enabled = $true` and fill in:
  - `VMware`  → `vCenters = @('vcenter01.contoso.com')`
  - `HyperV`  → `Hosts = @('hv01','hv02')` and/or `Clusters = @('hvcluster01')`
  - `Nutanix` → `Prisms = @('<cluster VIP from Find-OVPrism>')`
- **`Azure`** (optional) — `Enabled = $true`; leave `TenantScope = $true` to
  cover all subscriptions, or set `TenantScope = $false` and list
  `SubscriptionIds`. Set `TenantId` only to force a specific tenant.
- **`ConfigMgr`** (optional) — `Enabled = $true`, `SiteServer`, `SiteCode`.
- **`Licensing`** — replace `StandardPerCore` / `DatacenterPerCore` with the
  customer's **actual Open Value pricing** (the defaults are Microsoft suggested
  list, fine for a planning estimate but not a quote). Leave
  `HasSoftwareAssurance = $true` for Open Value. Set `PreferDatacenterAtVMCount`
  to a number (e.g. `8`) if the customer would rather standardize dense hosts on
  Datacenter for simplicity instead of the cheapest option; `0` always takes the
  cheapest.

---

## 8. Run it

```powershell
.\Invoke-OVAudit.ps1 -ConfigPath .\config.psd1
```

What to expect:

- You'll be prompted **once per credential realm** — AD/servers, then each
  enabled hypervisor, then SCCM. Azure pops its own `Connect-AzAccount` sign-in.
  Credentials are used in-session only and are **never written to disk**.
- The console narrates each phase and prints running counts, including
  **"N Windows Servers found OUTSIDE Active Directory"** — the discovery gap.

**First time at a new site, scope it small.** Point at one vCenter / one Prism
cluster (or a narrow AD `SearchBase`), confirm the output looks right, then widen
to the whole estate. This catches a wrong VIP or a bad credential in seconds
instead of after a full sweep.

---

## 9. Read and sanity-check the output (`.\output\`)

| File | What it is | What to check |
|---|---|---|
| `host-summary.csv` | Physical hypervisor hosts | **Real socket/core counts** appear (not blank, not the hyperthreaded number). A 2×18-core host should read 36 physical cores, not 72. |
| `inventory.csv` | Every server's detail | `Reachable` / `DataSource` columns — confirm the unreachable count is expected. Unreachable servers are excluded from the math, never assumed to have zero cores. |
| `discovery-coverage.csv` | Where each server was found | The `InAD = False` rows are servers AD missed (found via a hypervisor, Azure/Arc, or SCCM). This is the "what would have been overlooked" list. |
| `OV-Audit-Report.xlsx` (or `.html`) | The detailed workbook | Read the **Warnings** sheet in full: forced-Datacenter hosts, hosts missing core data, and any operational-premium notes. |
| `OV-Audit-Executive-Summary.pdf` / `.doc` | The customer deliverable | The recommended figure and the "savings vs Datacenter-everywhere" number look sane for the estate size. |

If a per-VM recommendation comes back, remember it counts *each* Windows VM — so
any VM the tool couldn't confirm as Windows (unreachable, no guest OS reported) is
left out and could make the count light. Reach those before trusting a per-VM
total.

---

## 10. After the run

- The output contains the customer's inventory (hostnames, IPs, core counts).
  Store it in the engagement's secure location, or delete it when you're done.
  **Do not commit it to a code repo.**
- `config.psd1` holds the customer's infrastructure details and is git-ignored.
  Don't commit or email it.
- The cost figures are **estimates for planning, not a quote.** Confirm the final
  position against the customer's live Microsoft Product Terms before quoting.

---

## 11. Troubleshooting

| Symptom | Fix |
|---|---|
| "Do you want to run..." prompts, or `...cannot be loaded because you opted not to run this software now` | Downloaded files carry the internet Mark-of-the-Web. Run `Get-ChildItem -Recurse -File \| Unblock-File` in the project folder, then re-run (section 2). |
| `ActiveDirectory module not found` | Install RSAT (section 2); confirm ADWS / TCP 9389 to a DC. |
| Many servers `unreachable` | WinRM not enabled on the targets, or 135 + dynamic RPC blocked. Enable WinRM via GPO (`winrm quickconfig`) or open the DCOM ports. |
| PowerCLI cert / connect error | The collector already ignores invalid certs; confirm TCP 443 and the read-only vCenter role. |
| Nutanix `Test-NetConnection` to the host fails on 9440 | Prism is on the CVM IPs / cluster VIP, not the AHV host IP. Run `tools/Find-OVPrism.ps1 -Subnet <first-3-octets>` to find the VIP. |
| Nutanix `SSL connection could not be established` / `unexpected error on a send` | TLS handshake failed from Windows PowerShell 5.1. Run from **PowerShell 7** (`pwsh`). |
| Nutanix `401 UNAUTHORIZED` | Wrong account/password, or that cluster uses a different local Prism account. Run the discovery helper per credential set. |
| Nutanix call still fails | Confirm 9440 is reachable, the Viewer account is valid, and you used the cluster **VIP** (Prism Element), not the AHV host IP. |
| Azure: `Az.ResourceGraph not found` | `Install-Module Az.Accounts, Az.ResourceGraph -Scope CurrentUser`, and run from PowerShell 7. |
| Azure: returns nothing | The account's **Reader** scope doesn't cover the right management group/subscriptions, or the servers aren't Arc-onboarded. Confirm with the pre-flight `Search-AzGraph` query (section 6). |
| Azure / network calls fail at the gateway | Sign into the **Global Secure Access** client first if the jump box uses one. |
| `.xlsx` not produced | `ImportExcel` isn't installed; the HTML report is written instead. |
| No PDF | No Edge/Chrome found; open the `.html` or `.doc` and export to PDF. |
