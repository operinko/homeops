#!/usr/bin/env pwsh
# Migration script for actions-runner-system namespace to ApplicationSet structure

$runners = @(
    @{name="gpro-frontend-runner"; shortName="gpro-frontend"; chart="gha-runner-scale-set"; repo="ghcr.io/actions/actions-runner-controller-charts"; version="0.13.0"},
    @{name="gpro-tool-runner"; shortName="gpro-tool"; chart="gha-runner-scale-set"; repo="ghcr.io/actions/actions-runner-controller-charts"; version="0.13.0"},
    @{name="home-ops-runner"; shortName="home-ops"; chart="gha-runner-scale-set"; repo="ghcr.io/actions/actions-runner-controller-charts"; version="0.13.0"}
)

Write-Host "Creating apps directory structure..."
New-Item -ItemType Directory -Path "kubernetes/argocd/applications/actions-runner-system/runners" -Force | Out-Null

foreach ($runner in $runners) {
    $appName = $runner.name
    $shortName = $runner.shortName
    $appDir = "kubernetes/argocd/applications/actions-runner-system/runners/$shortName"
    
    Write-Host "Processing $appName..."
    
    # Create app directory
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    
    # Create config.yaml
    $config = @"
---
app:
  name: $appName
  chartRepo: "$($runner.repo)"
  chartName: "$($runner.chart)"
  chartVersion: "$($runner.version)"
  enabled: true
"@
    Set-Content -Path "$appDir/config.yaml" -Value $config
    
    # Extract Helm values from existing Application
    $appFile = "kubernetes/argocd/applications/actions-runner-system/runners/$appName.yaml"
    if (Test-Path $appFile) {
        $content = Get-Content $appFile -Raw
        if ($content -match 'helm:\s+values:\s+\|(.+?)(?=\n  destination:|\n  syncPolicy:|\Z)') {
            $values = $matches[1].Trim()
            Set-Content -Path "$appDir/values.yaml" -Value $values
            Write-Host "  Extracted values for $appName"
        }
    }
    
    # Copy resources from old directory structure
    $oldResourcesDir = "kubernetes/argocd/applications/actions-runner-system/runners/$shortName"
    if (Test-Path $oldResourcesDir) {
        Get-ChildItem $oldResourcesDir -File | Where-Object { $_.Name -ne "config.yaml" } | ForEach-Object {
            Copy-Item $_.FullName -Destination $appDir -Force
        }
        Write-Host "  Copied resources for $appName"
    }
}

Write-Host "`nMigration complete!"
Write-Host "Review the generated files in kubernetes/argocd/applications/actions-runner-system/runners/"

