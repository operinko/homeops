#!/usr/bin/env pwsh
# Migration script for security namespace to ApplicationSet structure

$apps = @(
    @{name="authentik"; chart="authentik"; repo="https://charts.goauthentik.io"; version="2025.10.0"},
    @{name="vaultwarden"; chart="app-template"; repo="https://bjw-s-labs.github.io/helm-charts"; version="4.4.0"}
)

Write-Host "Creating apps directory structure..."
New-Item -ItemType Directory -Path "kubernetes/argocd/applications/security/apps" -Force | Out-Null

foreach ($app in $apps) {
    $appName = $app.name
    $appDir = "kubernetes/argocd/applications/security/apps/$appName"
    
    Write-Host "Processing $appName..."
    
    # Create app directory
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    
    # Create config.yaml
    $config = @"
---
app:
  name: $appName
  chartRepo: "$($app.repo)"
  chartName: "$($app.chart)"
  chartVersion: "$($app.version)"
  enabled: true
"@
    Set-Content -Path "$appDir/config.yaml" -Value $config
    
    # Extract Helm values from existing Application
    $appFile = "kubernetes/argocd/applications/security/$appName.yaml"
    if (Test-Path $appFile) {
        $content = Get-Content $appFile -Raw
        if ($content -match 'valuesObject:(.+?)(?=\n  destination:|\n  syncPolicy:|\Z)') {
            $valuesObject = $matches[1].Trim()
            # Convert valuesObject to proper YAML
            $values = $valuesObject -replace '^\s{8}', '' -replace '\n\s{8}', "`n"
            Set-Content -Path "$appDir/values.yaml" -Value $values
            Write-Host "  Extracted values for $appName"
        }
    }
    
    # Copy resources from old directory structure
    $oldResourcesDir = "kubernetes/argocd/applications/security/$appName"
    if (Test-Path $oldResourcesDir) {
        Get-ChildItem $oldResourcesDir -File | Where-Object { $_.Name -ne "config.yaml" } | ForEach-Object {
            Copy-Item $_.FullName -Destination $appDir -Force
        }
        Write-Host "  Copied resources for $appName"
    }
}

Write-Host "`nMigration complete!"
Write-Host "Review the generated files in kubernetes/argocd/applications/security/apps/"

