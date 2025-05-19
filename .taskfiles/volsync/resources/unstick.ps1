#!/usr/bin/env pwsh
# This script fixes a stuck VolSync snapshot
# Usage: ./unstick.ps1 <namespace> <app>

param (
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Namespace,
    
    [Parameter(Position = 1, Mandatory = $true)]
    [string]$App
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

# Step 1: Delete the ReplicationSource
Write-Step "Step 1: Deleting ReplicationSource $App in namespace $Namespace"
kubectl delete replicationsource $App -n $Namespace --ignore-not-found

# Step 2: Find and delete any stuck VolumeSnapshots
Write-Step "Step 2: Finding and deleting stuck VolumeSnapshots for $App in namespace $Namespace"
$snapshots = kubectl get volumesnapshot -n $Namespace -l volsync.backube/app=$App -o name 2>$null
if ($snapshots) {
    Write-Host "Found snapshots: $snapshots"
    foreach ($snapshot in $snapshots -split "`n") {
        if ($snapshot.Trim()) {
            Write-Host "Deleting snapshot: $snapshot"
            kubectl delete $snapshot -n $Namespace --ignore-not-found
        }
    }
} else {
    Write-Warning "No VolumeSnapshots found for $App in namespace $Namespace"
}

# Step 3: Find and delete any stuck VolumeSnapshotContents
Write-Step "Step 3: Finding and deleting stuck VolumeSnapshotContents for $App"
$snapshotContents = kubectl get volumesnapshotcontent -l volsync.backube/app=$App -o name 2>$null
if ($snapshotContents) {
    Write-Host "Found snapshot contents: $snapshotContents"
    foreach ($content in $snapshotContents -split "`n") {
        if ($content.Trim()) {
            Write-Host "Deleting snapshot content: $content"
            kubectl delete $content --ignore-not-found
        }
    }
} else {
    Write-Warning "No VolumeSnapshotContents found for $App"
}

# Step 4: Reconcile the Kustomization
Write-Step "Step 4: Reconciling Kustomization $App in namespace $Namespace"
flux reconcile kustomization $App -n $Namespace

# Step 5: Wait for ReplicationSource to be recreated
Write-Step "Step 5: Waiting for ReplicationSource to be recreated (30 seconds)"
Start-Sleep -Seconds 30

# Step 6: Manually trigger a new snapshot
Write-Step "Step 6: Manually triggering a new snapshot"
$timestamp = [int][double]::Parse((Get-Date -UFormat %s))
kubectl -n $Namespace patch replicationsource $App --type merge -p "{`"spec`":{`"trigger`":{`"manual`":`"$timestamp`"}}}"

Write-Success "Done! Check the status with: kubectl get replicationsource $App -n $Namespace"
