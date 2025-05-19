#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Migrates all VolSync applications to NFS storage classes.
.DESCRIPTION
    This script automates the process of migrating all VolSync applications to NFS storage classes.
    It uses the volsync-migrate-to-nfs.ps1 script to migrate each application.
.PARAMETER DeletePVCs
    If specified, the script will also delete PVCs related to the applications.
.PARAMETER DryRun
    If specified, the script will only show what would be done without making any changes.
.EXAMPLE
    ./migrate-all-volsync-apps.ps1
.EXAMPLE
    ./migrate-all-volsync-apps.ps1 -DeletePVCs
.EXAMPLE
    ./migrate-all-volsync-apps.ps1 -DryRun
#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$DeletePVCs,
    
    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

# Set colors for output
$infoColor = "Cyan"
$successColor = "Green"
$warningColor = "Yellow"
$errorColor = "Red"

function Write-Step {
    param (
        [string]$Message
    )
    Write-Host "➡️ $Message" -ForegroundColor $infoColor
}

function Write-Success {
    param (
        [string]$Message
    )
    Write-Host "✅ $Message" -ForegroundColor $successColor
}

function Write-Warning {
    param (
        [string]$Message
    )
    Write-Host "⚠️ $Message" -ForegroundColor $warningColor
}

function Write-Error {
    param (
        [string]$Message
    )
    Write-Host "❌ $Message" -ForegroundColor $errorColor
}

# Check if volsync-migrate-to-nfs.ps1 exists
if (-not (Test-Path -Path ".\volsync-migrate-to-nfs.ps1")) {
    Write-Error "volsync-migrate-to-nfs.ps1 not found in the current directory. Exiting."
    exit 1
}

# Get all ReplicationSources across all namespaces
Write-Step "Getting all ReplicationSources across all namespaces..."
$replicationSources = kubectl get replicationsource --all-namespaces -o json | ConvertFrom-Json

if (-not $replicationSources -or -not $replicationSources.items -or $replicationSources.items.Count -eq 0) {
    Write-Warning "No ReplicationSources found. Exiting."
    exit 0
}

Write-Success "Found $($replicationSources.items.Count) ReplicationSources"

# Process each ReplicationSource
foreach ($rs in $replicationSources.items) {
    $namespace = $rs.metadata.namespace
    $app = $rs.metadata.name
    
    Write-Step "Processing application '$app' in namespace '$namespace'..."
    
    $command = ".\volsync-migrate-to-nfs.ps1 -Namespace $namespace -App $app"
    if ($DeletePVCs) {
        $command += " -DeletePVCs"
    }
    if ($DryRun) {
        $command += " -DryRun"
    }
    
    Write-Host "Executing: $command" -ForegroundColor $infoColor
    Invoke-Expression $command
    
    Write-Success "Completed processing application '$app' in namespace '$namespace'"
    Write-Host "-----------------------------------------------------------"
}

Write-Success "All applications processed successfully"
