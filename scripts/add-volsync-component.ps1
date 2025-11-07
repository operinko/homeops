#!/usr/bin/env pwsh
# Add VolSync component to applications missing it

$apps = @(
    @{ name = "bazarr"; namespace = "media"; capacity = "10Gi"; uid = 568; gid = 568 }
    @{ name = "configarr"; namespace = "media"; capacity = "5Gi"; uid = 568; gid = 568 }
    @{ name = "huntarr"; namespace = "media"; capacity = "5Gi"; uid = 65534; gid = 65534 }
    @{ name = "prowlarr"; namespace = "media"; capacity = "10Gi"; uid = 568; gid = 568 }
    @{ name = "radarr"; namespace = "media"; capacity = "10Gi"; uid = 568; gid = 568 }
    @{ name = "readarr"; namespace = "media"; capacity = "10Gi"; uid = 568; gid = 568 }
    @{ name = "sabnzbd"; namespace = "media"; capacity = "10Gi"; uid = 568; gid = 568 }
    @{ name = "sonarr"; namespace = "media"; capacity = "10Gi"; uid = 568; gid = 568 }
    @{ name = "spotarr"; namespace = "media"; capacity = "5Gi"; uid = 65534; gid = 65534 }
    @{ name = "taggarr"; namespace = "media"; capacity = "5Gi"; uid = 65534; gid = 65534 }
    @{ name = "tautulli"; namespace = "media"; capacity = "10Gi"; uid = 568; gid = 568 }
    @{ name = "tvheadend"; namespace = "media"; capacity = "10Gi"; uid = 65534; gid = 65534 }
    @{ name = "wizarr"; namespace = "media"; capacity = "5Gi"; uid = 65534; gid = 65534 }
    @{ name = "crowdsec"; namespace = "network"; capacity = "5Gi"; uid = 65534; gid = 65534 }
    @{ name = "gatus"; namespace = "observability"; capacity = "5Gi"; uid = 65534; gid = 65534 }
    @{ name = "goldilocks"; namespace = "observability"; capacity = "5Gi"; uid = 65534; gid = 65534 }
    @{ name = "vaultwarden"; namespace = "security"; capacity = "5Gi"; uid = 65534; gid = 65534 }
)

foreach ($app in $apps) {
    $appName = $app.name
    $namespace = $app.namespace
    $capacity = $app.capacity
    $uid = $app.uid
    $gid = $app.gid

    $appDir = "kubernetes/argocd/applications/$namespace/apps/$appName"
    $kustomizationFile = "$appDir/kustomization.yaml"

    if (-not (Test-Path $appDir)) {
        Write-Host "Skipping $appName - directory not found: $appDir"
        continue
    }

    if (-not (Test-Path $kustomizationFile)) {
        Write-Host "Skipping $appName - kustomization.yaml not found"
        continue
    }

    Write-Host "Adding VolSync component to $appName..."

    $kustomization = Get-Content $kustomizationFile -Raw

    # Check if volsync component is already added
    if ($kustomization -match "components/volsync/ceph-rbd") {
        Write-Host "  VolSync component already present, skipping"
        continue
    }

    # Add components section if not present
    if ($kustomization -notmatch "components:") {
        # Find the position after apiVersion and kind
        $kustomization = $kustomization -replace "(kind: Kustomization)", "`$1`ncomponents:`n  - ../../../../components/volsync/ceph-rbd"
    } else {
        # Add to existing components section
        $kustomization = $kustomization -replace "(components:)", "`$1`n  - ../../../../components/volsync/ceph-rbd"
    }

    # Add configMapGenerator for volsync configuration
    $configMapGenerator = @"

configMapGenerator:
  - name: volsync-config
    literals:
      - APP=$appName
      - VOLSYNC_CAPACITY=$capacity
      - VOLSYNC_UID=$uid
      - VOLSYNC_GID=$gid
"@

    if ($kustomization -notmatch "configMapGenerator:") {
        $kustomization += $configMapGenerator
    } else {
        Write-Host "  ConfigMapGenerator already exists, please add manually:"
        Write-Host "    APP=$appName"
        Write-Host "    VOLSYNC_CAPACITY=$capacity"
        Write-Host "    VOLSYNC_UID=$uid"
        Write-Host "    VOLSYNC_GID=$gid"
    }

    $kustomization | Out-File -FilePath $kustomizationFile -Encoding utf8 -NoNewline
    Write-Host "  Updated kustomization.yaml"
}

Write-Host "`nDone! Added VolSync component to all missing apps."
Write-Host "Next steps:"
Write-Host "1. Review the changes"
Write-Host "2. Commit and push"
Write-Host "3. Let ArgoCD sync"

