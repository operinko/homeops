#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Unsticks a VolSync snapshot by deleting the associated job and pods.
.DESCRIPTION
    This script helps unstick a VolSync snapshot by deleting the associated job and pods.
    It can be used when a VolSync snapshot is stuck in a pending or running state.
.PARAMETER Namespace
    The namespace of the application.
.PARAMETER App
    The name of the application.
.PARAMETER DryRun
    If specified, the script will only show what would be done without making any changes.
.EXAMPLE
    ./unstick-volsync.ps1 -Namespace media -App sonarr
.EXAMPLE
    ./unstick-volsync.ps1 -Namespace media -App sonarr -DryRun
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Namespace,
    
    [Parameter(Mandatory = $true)]
    [string]$App,
    
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

function Execute-Command {
    param (
        [string]$Command,
        [string]$Description
    )
    
    Write-Step $Description
    
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would execute: $Command" -ForegroundColor $warningColor
        return $true
    }
    
    try {
        $output = Invoke-Expression $Command
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Command failed with exit code $LASTEXITCODE"
            return $false
        }
        return $true
    }
    catch {
        Write-Error "Error executing command: $_"
        return $false
    }
}

# Check for source job
$sourceJobName = "volsync-src-$App"
Write-Step "Checking for source job '$sourceJobName' in namespace '$Namespace'..."
$sourceJobExists = Execute-Command -Command "kubectl get job $sourceJobName -n $Namespace -o name 2>&1" -Description "Checking if source job exists"

if ($sourceJobExists) {
    # Delete the source job
    $deleteSourceJobSuccess = Execute-Command -Command "kubectl delete job $sourceJobName -n $Namespace" -Description "Deleting source job '$sourceJobName' in namespace '$Namespace'"
    if ($deleteSourceJobSuccess) {
        Write-Success "Source job deleted successfully"
    }
    else {
        Write-Warning "Failed to delete source job. Continuing..."
    }
}
else {
    Write-Warning "Source job '$sourceJobName' not found in namespace '$Namespace'. Skipping deletion."
}

# Check for destination job
$destJobName = "volsync-dst-$App"
Write-Step "Checking for destination job '$destJobName' in namespace '$Namespace'..."
$destJobExists = Execute-Command -Command "kubectl get job $destJobName -n $Namespace -o name 2>&1" -Description "Checking if destination job exists"

if ($destJobExists) {
    # Delete the destination job
    $deleteDestJobSuccess = Execute-Command -Command "kubectl delete job $destJobName -n $Namespace" -Description "Deleting destination job '$destJobName' in namespace '$Namespace'"
    if ($deleteDestJobSuccess) {
        Write-Success "Destination job deleted successfully"
    }
    else {
        Write-Warning "Failed to delete destination job. Continuing..."
    }
}
else {
    Write-Warning "Destination job '$destJobName' not found in namespace '$Namespace'. Skipping deletion."
}

# Check for manual destination job
$manualDestJobName = "volsync-dst-$App-manual"
Write-Step "Checking for manual destination job '$manualDestJobName' in namespace '$Namespace'..."
$manualDestJobExists = Execute-Command -Command "kubectl get job $manualDestJobName -n $Namespace -o name 2>&1" -Description "Checking if manual destination job exists"

if ($manualDestJobExists) {
    # Delete the manual destination job
    $deleteManualDestJobSuccess = Execute-Command -Command "kubectl delete job $manualDestJobName -n $Namespace" -Description "Deleting manual destination job '$manualDestJobName' in namespace '$Namespace'"
    if ($deleteManualDestJobSuccess) {
        Write-Success "Manual destination job deleted successfully"
    }
    else {
        Write-Warning "Failed to delete manual destination job. Continuing..."
    }
}
else {
    Write-Warning "Manual destination job '$manualDestJobName' not found in namespace '$Namespace'. Skipping deletion."
}

# Check for pods related to VolSync jobs
Write-Step "Checking for pods related to VolSync jobs for '$App' in namespace '$Namespace'..."
$volsyncPods = Execute-Command -Command "kubectl get pods -n $Namespace -l app.kubernetes.io/created-by=volsync -o name 2>&1" -Description "Checking for VolSync pods"

if ($volsyncPods) {
    # Delete the VolSync pods
    $deleteVolsyncPodsSuccess = Execute-Command -Command "kubectl delete pods -n $Namespace -l app.kubernetes.io/created-by=volsync" -Description "Deleting VolSync pods in namespace '$Namespace'"
    if ($deleteVolsyncPodsSuccess) {
        Write-Success "VolSync pods deleted successfully"
    }
    else {
        Write-Warning "Failed to delete VolSync pods. Continuing..."
    }
}
else {
    Write-Warning "No VolSync pods found in namespace '$Namespace'. Skipping deletion."
}

# Patch the ReplicationSource to trigger a new snapshot
Write-Step "Patching ReplicationSource '$App' in namespace '$Namespace' to trigger a new snapshot..."
$patchRsSuccess = Execute-Command -Command "kubectl patch replicationsource $App -n $Namespace --type merge -p '{\"spec\":{\"trigger\":{\"manual\":\"$(Get-Date -UFormat %s)\"}}'" -Description "Patching ReplicationSource"

if ($patchRsSuccess) {
    Write-Success "ReplicationSource patched successfully"
}
else {
    Write-Warning "Failed to patch ReplicationSource. You may need to manually trigger a new snapshot."
}

Write-Success "Unsticking process completed for '$App' in namespace '$Namespace'"
Write-Host "You can monitor the VolSync resources with: kubectl get replicationsource,replicationdestination -n $Namespace"
