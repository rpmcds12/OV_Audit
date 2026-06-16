# OV-Audit Run Sheet

A one-page checklist for running the audit on-site. **Everything is read-only.**
The tool only queries inventory (AD lookups, hypervisor API reads, WMI/CIM
reads). It never writes, changes, or restarts anything.

---

## 1. Where to run it

A domain-joined **admin workstation or member-server jump box**. **Not a domain
controller** (avoids installing tooling and using high-privilege credentials on a
tier-0 asset). The machine needs network and credential reach to every source you
enable.

## 2. Build the jump box

| Need | Install / check | Required when |
|---|---|---|
| PowerShell 5.1+ or 7.x | `$PSVersionTable.PSVersion` | always |
| RSAT ActiveDirectory module | `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` | always (server list + CALs) |
| VMware PowerCLI | `Install-Module VMware.PowerCLI -Scope CurrentUser` | VMware present |
| Hyper-V + FailoverClusters modules | `Add-WindowsCapability` / RSAT | Hyper-V present |
| Nutanix | nothing to install (uses `Invoke-RestMethod`) | AHV present |
| ImportExcel | `Install-Module ImportExcel -Scope CurrentUser` | optional, for `.xlsx` (HTML fallback otherwise) |
| Microsoft Edge or Chrome | already on most Windows | optional, for the PDF summary |

**Use PowerShell 7 (`pwsh`) when Nutanix is in scope.** Windows PowerShell 5.1's
TLS stack can fail the HTTPS handshake to recent Prism/AOS ("SSL connection could
not be established" / "unexpected error on a send"). PowerShell 7's modern stack
and `-SkipCertificateCheck` avoid it, and the collector takes that path on 7. The
rest of the audit runs on 5.1 too; 7 just also makes the per-server sweep faster.

If the files were copied from elsewhere, unblock and allow the session to run them:

```powershell
Get-ChildItem -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process Bypass -Force
```

## 3. Accounts and minimum rights

Use dedicated read accounts, not Domain Admin. Keep server-admin rights in a
tier-1 group, separate from any tier-0 (DC) accounts.

| Source | Account / rights |
|---|---|
| **Active Directory** | Any authenticated domain user (read access to computer/user objects is enough) |
| **Target servers (CIM)** | Local Administrator on the targets (WMI `root\cimv2` and `Get-WindowsFeature` need it). Add a dedicated domain group to local Administrators on member servers. |
| **VMware vCenter** | Built-in **Read-only** role at the vCenter root, propagated to children |
| **Hyper-V hosts** | Member of **Hyper-V Administrators** (or local admin) on each host; read access to the cluster |
| **Nutanix Prism** | A **Viewer** (read-only) Prism account |
| **SCCM/MECM** | **Read-only Analyst** role + remote WMI access to the SMS Provider |

## 4. Firewall ports (jump box -> source)

| Source | Ports |
|---|---|
| AD PowerShell module (ADWS) | **TCP 9389**, plus Kerberos 88 / DNS 53 for auth and name resolution |
| Per-server detail via WinRM | **TCP 5985** (HTTP) / **5986** (HTTPS) |
| Per-server detail via DCOM/WMI fallback | **TCP 135** + the dynamic RPC range **49152-65535** |
| VMware vCenter / ESXi | **TCP 443** |
| Nutanix Prism Element | **TCP 9440** |
| SCCM SMS Provider (WMI) | **TCP 135** + dynamic RPC **49152-65535** |

## 5. Pre-flight (verify before the full run)

```powershell
# AD reachable (uses ADWS 9389)
Get-ADDomain | Select-Object DNSRoot

# A sample target over WinRM (then DCOM if WinRM is off)
Test-WSMan SERVER01
Test-NetConnection SERVER01 -Port 135

# Hypervisor / SCCM endpoints
Test-NetConnection VCENTER01 -Port 443      # VMware
Get-CimInstance -ComputerName CM01 -Namespace root\sms -ClassName SMS_ProviderLocation  # SCCM
```

**Nutanix:** Prism does NOT run on the AHV host IP. It runs on the CVM IPs and
the cluster VIP (TCP 9440). To find the cluster VIP(s) to put in the config, run
the discovery helper from **PowerShell 7** (give it the first three octets of any
CVM/host IP on that subnet):

```powershell
pwsh ./tools/Find-OVPrism.ps1 -Subnet 198.18.244
```

It scans for 9440, queries each responder's `/cluster` endpoint, and prints the
distinct clusters with a ready-to-paste `Prisms = @(...)` line. Use the **VIP**
per cluster. (If different clusters use different local Prism accounts, run it
once per credential set with `-Credential (Get-Credential)`.)

## 6. Run

```powershell
Copy-Item .\config.example.psd1 .\config.psd1
notepad .\config.psd1
#  - Enable only the sources this site has (VMware / HyperV / Nutanix / ConfigMgr)
#  - Set vCenter / Hyper-V host / Prism VIP / SCCM site values
#  - Set Report.CustomerName and Report.PreparedBy
#  - Replace the reference prices with the customer's actual Open Value pricing
#  - Confirm Licensing.HasSoftwareAssurance and (optional) PreferDatacenterAtVMCount

.\Invoke-OVAudit.ps1 -ConfigPath .\config.psd1
```

You will be prompted once per credential realm (AD/servers, each hypervisor,
SCCM). Credentials are used in-session and never written to disk.

**First time at a new site:** scope it small first. Point at one vCenter / one
Prism cluster (or a narrow AD `SearchBase`), confirm the output looks right, then
widen.

## 7. Validate the output (`.\output\`)

- `host-summary.csv` shows **real socket/core counts** for every host (not blanks, not guest vCPUs).
- `inventory.csv` `Reachable` / `DataSource` columns: confirm the unreachable count is expected; unreachable servers are excluded from the math, never assumed zero-core.
- `OV-Audit-Report.xlsx` Warnings sheet: read every warning (forced-Datacenter hosts, hosts missing core data, preference premiums).
- `OV-Audit-Executive-Summary.pdf/.doc`: the recommended figure and the savings-vs-Datacenter number look sane.

## 8. After the run

- Output contains customer inventory data. Store it in the engagement's secure location or delete it when done.
- `config.psd1` holds the customer's infrastructure details and is git-ignored. Do not commit or email it.
- The cost figures are **estimates for planning, not a quote**. Confirm the final position against the customer's live Microsoft Product Terms before quoting.

## 9. Quick troubleshooting

| Symptom | Fix |
|---|---|
| `ActiveDirectory module not found` | Install RSAT (section 2); confirm ADWS / TCP 9389 to a DC |
| Many servers `unreachable` | WinRM not enabled on targets, or 135 + dynamic RPC blocked. Enable WinRM (`winrm quickconfig` via GPO) or open DCOM |
| PowerCLI cert / connect error | The collector already sets `InvalidCertificateAction Ignore`; confirm 443 and the read-only role |
| Nutanix `Test-NetConnection` to the host fails on 9440 | Prism is on the CVM IPs / cluster VIP, not the AHV host IP. Run `tools/Find-OVPrism.ps1 -Subnet <first-3-octets>` to find the VIP |
| Nutanix `SSL connection could not be established` / `unexpected error on a send` | TLS handshake failed from Windows PowerShell 5.1. Run from **PowerShell 7** (`pwsh`) |
| Nutanix `401 UNAUTHORIZED` | Wrong account/password, or that cluster uses a different local Prism account than the one you supplied. Run the discovery helper per credential set |
| Nutanix call still fails | Confirm 9440 reachable, the Viewer account, and that you used the cluster **VIP** (Prism Element), not the AHV host IP |
| `.xlsx` not produced | `ImportExcel` not installed; the HTML report is written instead |
| No PDF | No Edge/Chrome found; open the `.html` or `.doc` and export to PDF |
