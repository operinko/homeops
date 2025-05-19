#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Migrates VolSync resources from iSCSI to NFS storage classes.
.DESCRIPTION
    This script automates the process of migrating VolSync resources from iSCSI to NFS storage classes.
    It suspends the application's kustomization, deletes the existing VolSync resources, and then resumes
    the kustomization to recreate the resources with the new storage classes.
.PARAMETER Namespace
    The namespace of the application to migrate.
.PARAMETER App
    The name of the application to migrate.
.PARAMETER DeletePVCs
    If specified, the script will also delete PVCs related to the application.
.PARAMETER DryRun
    If specified, the script will only show what would be done without making any changes.
.EXAMPLE
    ./volsync-migrate-to-nfs.ps1 -Namespace media -App sonarr
.EXAMPLE
    ./volsync-migrate-to-nfs.ps1 -Namespace media -App sonarr -DeletePVCs
.EXAMPLE
    ./volsync-migrate-to-nfs.ps1 -Namespace media -App sonarr -DryRun
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Namespace,
    
    [Parameter(Mandatory = $true)]
    [string]$App,
    
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

# Check if the application exists
Write-Step "Checking if application '$App' exists in namespace '$Namespace'..."
$appExists = Execute-Command -Command "kubectl get deployment $App -n $Namespace -o name 2>&1" -Description "Checking if application exists"
if (-not $appExists) {
    # Try checking for statefulset
    $appExists = Execute-Command -Command "kubectl get statefulset $App -n $Namespace -o name 2>&1" -Description "Checking if application exists as StatefulSet"
    if (-not $appExists) {
        Write-Warning "Application '$App' not found in namespace '$Namespace'. Continuing anyway as it might be using a different resource type."
    }
}

# Check if kustomization exists
Write-Step "Checking if kustomization '$App' exists in namespace '$Namespace'..."
$ksExists = Execute-Command -Command "flux get kustomization $App -n $Namespace 2>&1" -Description "Checking if kustomization exists"
if (-not $ksExists) {
    Write-Error "Kustomization '$App' not found in namespace '$Namespace'. Exiting."
    exit 1
}

# Step 1: Suspend the application's kustomization
$suspendSuccess = Execute-Command -Command "flux suspend kustomization $App -n $Namespace" -Description "Suspending kustomization '$App' in namespace '$Namespace'"
if (-not $suspendSuccess) {
    Write-Error "Failed to suspend kustomization. Exiting."
    exit 1
}
Write-Success "Kustomization suspended successfully"

# Step 2: Delete the ReplicationSource if it exists
Write-Step "Checking for ReplicationSource '$App' in namespace '$Namespace'..."
$rsExists = Execute-Command -Command "kubectl get replicationsource $App -n $Namespace -o name 2>&1" -Description "Checking if ReplicationSource exists"
if ($rsExists) {
    $deleteRsSuccess = Execute-Command -Command "kubectl delete replicationsource $App -n $Namespace" -Description "Deleting ReplicationSource '$App' in namespace '$Namespace'"
    if ($deleteRsSuccess) {
        Write-Success "ReplicationSource deleted successfully"
    }
    else {
        Write-Warning "Failed to delete ReplicationSource. Continuing..."
    }
}
else {
    Write-Warning "ReplicationSource '$App' not found in namespace '$Namespace'. Skipping deletion."
}

# Step 3: Delete the ReplicationDestination if it exists
Write-Step "Checking for ReplicationDestination '$App-dst' in namespace '$Namespace'..."
$rdExists = Execute-Command -Command "kubectl get replicationdestination $App-dst -n $Namespace -o name 2>&1" -Description "Checking if ReplicationDestination exists"
if ($rdExists) {
    $deleteRdSuccess = Execute-Command -Command "kubectl delete replicationdestination $App-dst -n $Namespace" -Description "Deleting ReplicationDestination '$App-dst' in namespace '$Namespace'"
    if ($deleteRdSuccess) {
        Write-Success "ReplicationDestination deleted successfully"
    }
    else {
        Write-Warning "Failed to delete ReplicationDestination. Continuing..."
    }
}
else {
    Write-Warning "ReplicationDestination '$App-dst' not found in namespace '$Namespace'. Skipping deletion."
}

# Step 4: Delete PVCs if requested
if ($DeletePVCs) {
    Write-Step "Checking for PVC '$App' in namespace '$Namespace'..."
    $pvcExists = Execute-Command -Command "kubectl get pvc $App -n $Namespace -o name 2>&1" -Description "Checking if PVC exists"
    if ($pvcExists) {
        $deletePvcSuccess = Execute-Command -Command "kubectl delete pvc $App -n $Namespace" -Description "Deleting PVC '$App' in namespace '$Namespace'"
        if ($deletePvcSuccess) {
            Write-Success "PVC deleted successfully"
        }
        else {
            Write-Warning "Failed to delete PVC. Continuing..."
        }
    }
    else {
        Write-Warning "PVC '$App' not found in namespace '$Namespace'. Skipping deletion."
    }
    
    # Check for cache PVCs
    Write-Step "Checking for cache PVCs related to '$App' in namespace '$Namespace'..."
    $cachePvcs = Execute-Command -Command "kubectl get pvc -n $Namespace -l volsync.backube/app=$App -o name 2>&1" -Description "Checking for cache PVCs"
    if ($cachePvcs) {
        $deleteCachePvcsSuccess = Execute-Command -Command "kubectl delete pvc -n $Namespace -l volsync.backube/app=$App" -Description "Deleting cache PVCs for '$App' in namespace '$Namespace'"
        if ($deleteCachePvcsSuccess) {
            Write-Success "Cache PVCs deleted successfully"
        }
        else {
            Write-Warning "Failed to delete cache PVCs. Continuing..."
        }
    }
    else {
        Write-Warning "No cache PVCs found for '$App' in namespace '$Namespace'. Skipping deletion."
    }
}

# Step 5: Resume the application's kustomization
$resumeSuccess = Execute-Command -Command "flux resume kustomization $App -n $Namespace" -Description "Resuming kustomization '$App' in namespace '$Namespace'"
if (-not $resumeSuccess) {
    Write-Error "Failed to resume kustomization. Please check the status and resume manually."
    exit 1
}
Write-Success "Kustomization resumed successfully"

# Step 6: Trigger reconciliation
$reconcileSuccess = Execute-Command -Command "flux reconcile kustomization $App -n $Namespace" -Description "Triggering reconciliation for kustomization '$App' in namespace '$Namespace'"
if (-not $reconcileSuccess) {
    Write-Warning "Failed to trigger reconciliation. The kustomization will reconcile based on its configured interval."
}
else {
    Write-Success "Reconciliation triggered successfully"
}

Write-Success "Migration process completed for '$App' in namespace '$Namespace'"
Write-Host "You can check the status with: flux get kustomization $App -n $Namespace"
Write-Host "And monitor the VolSync resources with: kubectl get replicationsource,replicationdestination -n $Namespace"
