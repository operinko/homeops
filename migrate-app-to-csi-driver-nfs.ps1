#!/usr/bin/env pwsh

# Script to migrate an application from democratic-csi to csi-driver-nfs
# Usage: .\migrate-app-to-csi-driver-nfs.ps1 -Namespace <namespace> -App <app> [-DeletePVCs] [-DryRun]

param(
    [Parameter(Mandatory=$true)]
    [string]$Namespace,
    
    [Parameter(Mandatory=$true)]
    [string]$App,
    
    [switch]$DeletePVCs,
    [switch]$DryRun
)

# Colors for output
$infoColor = "Cyan"
$successColor = "Green"
$warningColor = "Yellow"
$errorColor = "Red"

function Write-Step {
    param ([string]$Message)
    Write-Host "➡️ $Message" -ForegroundColor $infoColor
}

function Write-Success {
    param ([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor $successColor
}

function Write-Warning {
    param ([string]$Message)
    Write-Host "⚠️ $Message" -ForegroundColor $warningColor
}

function Write-Error {
    param ([string]$Message)
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

Write-Host "🚀 Starting migration of $App in namespace $Namespace to CSI-Driver-NFS" -ForegroundColor $infoColor

# Step 1: Check if CSI-Driver-NFS is available
Write-Step "Checking if CSI-Driver-NFS storage class is available..."
if (-not $DryRun) {
    try {
        kubectl get storageclass nfs-csi | Out-Null
        Write-Success "CSI-Driver-NFS storage class found"
    }
    catch {
        Write-Error "CSI-Driver-NFS storage class 'nfs-csi' not found. Please deploy CSI-Driver-NFS first."
        exit 1
    }
} else {
    Write-Warning "[DRY RUN] Assuming CSI-Driver-NFS is available"
}

# Step 2: Create backup with current system
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$patchJson = "{`"spec`":{`"trigger`":{`"manual`":`"pre-migration-$timestamp`"}}}"
Execute-Command "kubectl patch replicationsource $App -n $Namespace --type=merge -p '$patchJson'" "Triggering pre-migration backup"

# Step 3: Wait for backup to complete
if (-not $DryRun) {
    Write-Step "Waiting for backup to complete..."
    $timeout = 600 # 10 minutes
    $elapsed = 0
    $interval = 10
    
    while ($elapsed -lt $timeout) {
        try {
            $status = kubectl get replicationsource $App -n $Namespace -o jsonpath='{.status.lastSyncTime}' 2>$null
            if ($status) {
                Write-Success "Backup completed at: $status"
                break
            }
        }
        catch {
            # Continue waiting
        }
        
        Write-Host "Waiting for backup to complete..." -ForegroundColor $warningColor
        Start-Sleep $interval
        $elapsed += $interval
    }
    
    if ($elapsed -ge $timeout) {
        Write-Warning "Backup timeout reached, proceeding with migration"
    }
}

# Step 4: Suspend application
Execute-Command "flux suspend kustomization $App -n flux-system" "Suspending application Flux kustomization"

# Try to scale down deployment or statefulset
$scaleCommand = @"
try { kubectl scale deployment/$App --replicas=0 -n $Namespace 2>`$null } catch { 
    try { kubectl scale statefulset/$App --replicas=0 -n $Namespace 2>`$null } catch { 
        Write-Host 'No deployment or statefulset to scale' 
    } 
}
"@
Execute-Command $scaleCommand "Scaling down application"

# Step 5: Wait for pods to terminate
if (-not $DryRun) {
    Write-Step "Waiting for application pods to terminate..."
    try {
        kubectl wait pod --for=delete --selector="app.kubernetes.io/name=$App" --timeout=300s -n $Namespace
        Write-Success "Application pods terminated"
    }
    catch {
        Write-Warning "Some pods may still be terminating, continuing..."
    }
}

# Step 6: Delete PVCs if requested
if ($DeletePVCs) {
    Execute-Command "kubectl delete pvc $App -n $Namespace --ignore-not-found=true" "Deleting existing PVC"
}

# Step 7: Resume application with new storage class
Execute-Command "flux resume kustomization $App -n flux-system" "Resuming application Flux kustomization"

Write-Success "Migration completed! Application $App should now be using CSI-Driver-NFS storage."
Write-Warning "Please verify the application is working correctly and that data is accessible."

Write-Host "🎉 Migration of $App to CSI-Driver-NFS completed successfully!" -ForegroundColor $successColor
