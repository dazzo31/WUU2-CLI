#Requires -Version 5.1
<#
.DESCRIPTION
Application CONFIGURATION: the single home for the $global:* startup settings (version and its
provenance, logging flag, timeouts, operation deadlines, credentials, concurrency and paths).
Extracted from Wuu.Core.psm1 (instructions SS8: Core should become a bootstrap/orchestration layer).

WHY THIS IS A MODULE AND NOT MODULE-SCOPE CODE IN CORE. The region used to be a block inside
Start-WuuApplication. It is still evaluated at STARTUP, by an explicit call at exactly the point
the block occupied, so every $global: is set before anything reads it. What changed is only that
configuration is no longer tangled with orchestration.

ONE CONSTRAINT TRAVELS WITH IT: the version literal must be assigned BEFORE the resolver runs, or
the literal overwrites the resolved value and the provenance silently reverts to the embedded
string. The order is preserved here and must stay. THE VERSION SINGLE-SOURCING GATE READS THIS
FILE (Scripts\Validate-Release.ps1 version guard and Test-ReleaseMetadata (g)) - do not add a
second $global:WuuVersion assignment anywhere, and re-point those readers if this file moves again.
#>

function Initialize-WuuConfiguration {
    <#
    .SYNOPSIS Applies the application's $global:* settings. Called once, at startup.
    .DESCRIPTION Takes $WuuRoot because several paths are derived from it. Returns nothing: every
    effect is a $global: assignment, which is what lets the caller stay a thin bootstrap step.
    #>
    param([Parameter(Mandatory)][string]$WuuRoot)


# The ONE application version. $global: so Wuu.Logging (banner) and Wuu.Audit (wuuVersion on every
# record) read the same value; the release gate checks it against the git tag at HEAD. A prerelease string
# marks every audit record as pre-release evidence - never reuse it for a final release.
# Release notes: docs/RELEASE_NOTES_<version>.md. Invariant status: .github/copilot-instructions.md Appendix A.
$global:WuuVersion = 'v1.5.0-beta.6-cli'

# SS18: PROVENANCE, immediately after the literal so the resolved value cannot be overwritten by it.
#
# WHY THE ORDER MATTERS AND WHY THIS IS NOT AT MODULE SCOPE. This whole configuration region lives
# inside Start-WuuApplication, not at module top level, so the literal above is evaluated when the
# application starts. An earlier placement of this block was ABOVE the literal - the resolver ran
# first, then the literal overwrote it, silently reverting to the embedded value. That is the same
# class of bug as the version mismatch this is meant to prevent, which is why the resolved value is
# written after the literal and nowhere else.
#
# A git tag at HEAD wins (provenance for an operator, and it self-corrects when a release is tagged);
# otherwise the embedded literal stands. A DISAGREEMENT is reported rather than quietly resolved:
# the version is written on every audit record, so picking a winner silently is exactly how evidence
# would end up labelled with a build that did not produce it.
#
# A release zip has no .git, so an operator running the packaged build legitimately falls back to the
# embedded value - that is an expected case, not an error.
try {
    $versionInfo = Resolve-WuuVersion -Embedded $global:WuuVersion -RepoRoot $WuuRoot
    if ($versionInfo) {
        if ($versionInfo.Version) { $global:WuuVersion = [string]$versionInfo.Version }
        $global:WuuVersionSource = [string]$versionInfo.Source
        $global:WuuVersionTag = [string]$versionInfo.Tag
        if ($versionInfo.Mismatch) {
            Write-Warning ("Version mismatch: $($versionInfo.Note). Audit records will carry '$global:WuuVersion' (source: $global:WuuVersionSource). Fix the embedded literal or re-tag.")
        }
    }
} catch {
    Write-Warning "Could not resolve the version from the repository; using '$global:WuuVersion'."
}
if ($global:WuuVersionSource -eq 'tag') {
    Write-Host ("  Version {0} (from git tag)" -f $global:WuuVersion) -ForegroundColor DarkGray
}

# Toggle debug logging. DEFAULT IS OFF.
#
# WHY OFF. This is a patch-management tool, so the default has to suit unattended operation: a
# scheduled task or a CI job cannot act on a log size it was never told about. With verbose logging
# on by default the consequences are real rather than cosmetic - large logs, unnecessary I/O on
# every run, extra filesystem contention, operational detail written to disk by default, and
# diagnostic noise interleaved with the audit records an ISO 27001 review reads.
#
# The comment here used to claim "$false by default" while the assignment said $true - the file's
# own history block and the README both described the off default. The code was the outlier.
#
# HOW TO TURN IT ON WITHOUT EDITING SOURCE (editing a shipped file is not a supported way to change
# behaviour - a reinstall silently reverts it, and the change is invisible to anyone reading the
# configuration):
#   1. environment variable  WUU_DEBUG=1   (best for a scheduled task or a CI job)
#   2. source edit                          (last resort - see the warning above)
# There is deliberately no config-file key for this yet: the only config the tool carries is the
# encrypted computer list, and inventing a half-plumbed setting would be worse than the env var.
# The env var wins over the default, so an operator can force it on for one run without touching
# anything persistent.
$global:EnableDebugLogging = $false

# Apply the overrides. Kept here, immediately after the default, so there is one place to read for
# "how is this decided?" rather than a value here and a re-assignment far away.
try {
    if ($env:WUU_DEBUG -and @('1', 'true', 'yes', 'on') -contains $env:WUU_DEBUG.ToLowerInvariant()) {
        $global:EnableDebugLogging = $true
    }
} catch {
    # A malformed environment value must not stop startup; the default (off) stands.
    Write-Warning "Could not interpret WUU_DEBUG='$($env:WUU_DEBUG)'; debug logging stays disabled."
}
# SS18 provenance ($global:WuuVersionSource / $global:WuuVersionTag) is set with the version itself,
# further up this region - the resolver has to run AFTER the literal, or the literal overwrites it.
if ($global:EnableDebugLogging) {
    Write-Host '  Debug logging is ENABLED (verbose; large logs).' -ForegroundColor Yellow
}

# Timeout settings (seconds)
$global:sessionTimeout = 30       # Timeout for creating Windows Update session
$global:searchTimeout = 300       # Timeout for update search operation
$global:rebootCheckTimeout = 60   # Timeout for reboot check

# Timeout settings for remote probes and bounded operations (seconds).
# Centralised so remote probes no longer depend on hardcoded literals.
$global:CimTimeoutSeconds         = 10   # was hardcoded 5 in Remote/Credentials probes
$global:ServiceTimeoutSeconds     = 10   # was hardcoded 5
$global:PerformanceTimeoutSeconds = 60   # was unbounded raw CIM in Get-SystemPerformance
$global:CredProbeTimeoutSeconds   = 10   # was hardcoded 5 in WindowsUpdate runspace
$global:RebootProbeTimeoutSeconds = 10   # online probe inside reboot wait
$global:OfflineWaitSeconds        = 600  # was hardcoded inline in $RestartComputer
$global:OnlineWaitSeconds         = 1800 # was hardcoded inline in $RestartComputer
# SS7: the management-endpoint probe used instead of ICMP for state transitions.
# 135 is the RPC endpoint mapper, which the DCOM/CIM calls actually depend on. 3s is long enough for
# a LAN host and short enough that a reboot wait loop stays responsive.
$global:EndpointProbePort         = 135
$global:EndpointProbeTimeoutMs    = 3000
# SS12: how many CONSECUTIVE connectivity failures justify removing a computer from the set.
# More than one, because a single blip used to be enough to evict a healthy server.
$global:ConnectivityFailuresBeforeRemoval = 2

# SS5: OPERATION-SPECIFIC deadlines (seconds), keyed by the op handed to Start-UpdateCheckJob.
# WHY PER OP AND NOT ONE NUMBER. The cleanup loop force-stopped every job at a flat 10 minutes
# (Core, "Job timeout detected"). Windows Update has no single sensible deadline:
#   * a SEARCH can legitimately take 20+ minutes on a large estate against WSUS, so a flat 10 was
#     killing healthy work and reporting a false timeout (the "10 minute hard stop" in the findings);
#   * an INSTALL can take hours (an in-place servicing stack update alone can exceed 10 minutes);
#   * a restart is the LONGEST - the offline and online waits are 600s + 1800s, so 10 minutes
#     guaranteed a false timeout on EVERY reboot;
#   * a SERVICE action that has not returned in 5 minutes is stuck, not slow.
# A single number cannot express that, and choosing the largest one would mean a genuinely hung
# service restart occupied a runspace for 45 minutes before anyone noticed.
#
# The deadline is recorded per computer (TimeoutExpiresAt/TimeoutSource) when the job is SUBMITTED,
# so the decision is inspectable while the job is still running and is not recomputed from a
# start time that a restart could reset.
$global:OperationTimeoutSeconds = @{
    'Check'            = 2700   # 45 min - large-estate search + download scan
    'Download'         = 2700   # 45 min
    'InstallAndRecheck'= 7200   # 2 h   - servicing-stack installs are genuinely slow
    'AutoFlow'         = 14400  # 4 h   - full chain, must exceed its own reboot waits
    'Restart'          = 2700   # 45 min - covers OfflineWait + OnlineWait (600 + 1800) with margin
    'RemoveOffline'    = 300    # 5 min - a connectivity probe
    'ServiceAction'    = 300    # 5 min - a hung service control is stuck, not slow
    'default'          = 1800   # 30 min - anything unrecognised: bounded, but not punishing
}
# How often a running job refreshes its heartbeat. The deadline is the BACKSTOP; the heartbeat is
# what distinguishes "still working" from "hung", and it is what the status line reports.
$global:OperationHeartbeatSeconds = 30

# Enhanced error handling toggle. Set to $true to enable advanced error handling.
$global:EnableEnhancedErrorHandling = $true

# Custom credentials for remote WMI queries
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$global:CredentialCache = @{}
$global:CredentialConfig = @{ Username = ''; Domain = ''; UseCredentials = $false }
# Phase 1: monotonic counter bumped whenever the credential configuration changes. Stamped onto a
# row when its runspace is built, so a submission under changed credentials rebuilds the runspace
# instead of silently reusing one that captured the previous identity.
$global:CredentialEpoch = 0

# Job throttling. Must not exceed $script:MaxPoolSize in Wuu.Workers (probes run on that pool); raise both
# together. Test-PoolCompatibility and gate block (ax) enforce it.
$global:MaxConcurrentJobs = 10
# Performance thresholds for operations
$global:PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }

# Background processing control (synchronized for runspace access)
$global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })

# File paths and external tool configuration
$global:ConfigPaths = @{
    DownloadScript = Join-Path $WuuRoot 'Scripts\Download-Patches.ps1'
    InstallScript = Join-Path $WuuRoot 'Scripts\Install-Patches.ps1'
    ComputerListConfig = Join-Path $WuuRoot 'ComputerList.config'
    LogDirectory = $WuuRoot
}

# Validation of required external files
$requiredFiles = @('Scripts\Download-Patches.ps1', 'Scripts\Install-Patches.ps1')
foreach ($file in $requiredFiles) {
    $fullPath = Join-Path $WuuRoot $file
    if (-not (Test-Path $fullPath)) {
        Write-Warning "Required file not found: $fullPath - functionality may be impaired"
    }
}

}

Export-ModuleMember -Function @('Initialize-WuuConfiguration')
