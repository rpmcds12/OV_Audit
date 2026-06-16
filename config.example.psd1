@{
    # ─────────────────────────────────────────────────────────────────────
    #  OV-Audit configuration. Copy to config.psd1 and edit.
    #  Everything here is READ access only.
    # ─────────────────────────────────────────────────────────────────────

    # Where to write reports (created if missing).
    OutputPath = '.\output'

    # ── Customer-facing report ────────────────────────────────────────────
    Report = @{
        CustomerName = 'Contoso Ltd'
        PreparedBy   = 'US Signal'
        # Build the executive summary deliverable: HTML always, a Word-openable
        # .doc, and a PDF if Edge/Chrome is available on the machine.
        ExecutiveSummary = $true
    }

    # ── Active Directory ──────────────────────────────────────────────────
    ActiveDirectory = @{
        Enabled = $true
        # Leave $null to use the current domain. Or set a specific server / SearchBase.
        Server     = $null
        SearchBase = $null   # e.g. 'OU=Servers,DC=contoso,DC=com'
        # Only include enabled computer accounts whose OS looks like Windows Server.
        ServerOsFilter = '*Server*'
        # Estimate CAL footprint from enabled user/device counts.
        CountCals = $true
    }

    # ── VMware (PowerCLI) ─────────────────────────────────────────────────
    VMware = @{
        Enabled   = $false
        vCenters  = @('vcenter01.contoso.com')   # one or more vCenters or ESXi hosts
        # Credential prompt at runtime unless you wire up a secret store.
    }

    # ── Microsoft Hyper-V ─────────────────────────────────────────────────
    HyperV = @{
        Enabled = $false
        # Standalone hosts and/or failover-cluster names.
        Hosts    = @()                  # e.g. 'hv01','hv02'
        Clusters = @()                  # e.g. 'hvcluster01'
    }

    # ── Nutanix AHV (Prism Element REST API v2.0) ─────────────────────────
    Nutanix = @{
        Enabled = $false
        # One Prism Element cluster VIP (or CVM IP) per cluster. For Prism
        # Central multi-cluster, list each managed cluster's PE VIP here.
        Prisms  = @('10.0.0.10')        # https://<ip>:9440
        Port    = 9440
        # Credential prompt at runtime (a read-only Prism viewer account is enough).
    }

    # ── SCCM / MECM (optional supplement) ─────────────────────────────────
    ConfigMgr = @{
        Enabled    = $false
        SiteServer = $null              # e.g. 'cm01.contoso.com'
        SiteCode   = $null              # e.g. 'P01'
    }

    # ── Licensing assumptions (drives the cheapest-compliant recommendation) ─
    Licensing = @{
        # Per-core prices in USD. Defaults are Microsoft SUGGESTED LIST
        # (Standard 16-core pack $1,176 => $73.50/core; Datacenter 16-core
        # pack $6,771 => $423.19/core). OVERRIDE with the customer's actual
        # Open Value pricing for a real number.
        StandardPerCore   = 73.50
        DatacenterPerCore = 423.19
        # Open Value (esp. Company-Wide / OV Subscription) typically INCLUDES
        # Software Assurance. SA unlocks the per-VM option, Flexible
        # Virtualization (BYOL to a hoster), AHB, and avoids licensing every
        # cluster node. Set $false only if SA is genuinely absent.
        HasSoftwareAssurance = $true
        # Currency label for the report.
        Currency = 'USD'
        # Treat clustered hosts (HA/vMotion/Live Migration) as requiring
        # Datacenter when no SA is present (90-day reassignment rule forces
        # licensing every potential target host).
        ClusterForcesDatacenterWithoutSA = $true
        # Operational-simplicity override: flip any host running at least this
        # many Windows VMs to Datacenter even when per-VM / stacked-Standard is
        # cheaper. The report still shows the lowest-cost option and the premium
        # this choice costs. 0 = always recommend the cheapest compliant option.
        PreferDatacenterAtVMCount = 0
    }

    # ── Per-server detail collection ──────────────────────────────────────
    ServerDetail = @{
        # Try WinRM first, fall back to DCOM/WMI for older boxes.
        PreferWinRM   = $true
        AllowDcomFallback = $true
        # Detect SQL Server instances/editions.
        CollectSql    = $true
        # Detect installed roles/features (RDS, etc.).
        CollectRoles  = $true
        # Parallel CIM throttle (PS7 ForEach-Object -Parallel; ignored on 5.1).
        ThrottleLimit = 16
        # Per-host timeout (seconds).
        TimeoutSec    = 30
    }
}
