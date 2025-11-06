#!/usr/bin/env pwsh
# Migrate observability namespace apps to ApplicationSet structure

$apps = @(
    @{name="gatus"; chart="app-template"; repo="https://bjw-s-labs.github.io/helm-charts"; version="4.4.0"},
    @{name="goldilocks"; chart="goldilocks"; repo="https://charts.fairwinds.com/stable"; version="10.1.0"},
    @{name="grafana"; chart="grafana"; repo="ghcr.io/grafana/helm-charts"; version="10.1.4"},
    @{name="kromgo"; chart="app-template"; repo="https://bjw-s-labs.github.io/helm-charts"; version="4.4.0"},
    @{name="kube-prometheus-stack"; chart="kube-prometheus-stack"; repo="ghcr.io/prometheus-community/charts"; version="79.1.1"},
    @{name="loki"; chart="loki"; repo="https://grafana.github.io/helm-charts"; version="6.45.2"},
    @{name="unpoller"; chart="app-template"; repo="https://bjw-s-labs.github.io/helm-charts"; version="4.4.0"}
)

foreach ($app in $apps) {
    $appName = $app.name
    Write-Host "Processing $appName..." -ForegroundColor Cyan

    # Create app directory
    $appDir = "kubernetes/argocd/applications/observability/apps/$appName"
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null

    # Create config.yaml with chart info
    $config = @"
---
# Configuration for $appName application
# Used by ApplicationSet generator
app:
  name: $appName
  chartRepo: "$($app.repo)"
  chartName: "$($app.chart)"
  chartVersion: "$($app.version)"
  enabled: true
"@
    Set-Content -Path "$appDir/config.yaml" -Value $config

    # Extract Helm values from Application YAML
    $appYaml = "kubernetes/argocd/applications/observability/$appName.yaml"
    if (Test-Path $appYaml) {
        $content = Get-Content $appYaml -Raw

        # Extract values between "valuesObject:" and "destination:"
        if ($content -match '(?s)valuesObject:\s*\n(.*?)\n  destination:') {
            $values = $matches[1]

            # Remove leading 8 spaces from each line
            $values = $values -replace '(?m)^        ', ''

            # Create values.yaml
            $output = "---`n# Helm values for $appName deployment`n$values"
            Set-Content -Path "$appDir/values.yaml" -Value $output
            Write-Host "  ✓ Extracted values.yaml" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Could not extract values from $appName" -ForegroundColor Yellow
        }
    }

    # Copy resource files from old -resources directory
    $oldDir = "kubernetes/argocd/applications/observability/$appName-resources"
    if (Test-Path $oldDir) {
        Get-ChildItem $oldDir -File -Recurse | ForEach-Object {
            $relativePath = $_.FullName.Substring($oldDir.Length + 1)
            $targetPath = Join-Path $appDir $relativePath
            $targetDir = Split-Path $targetPath -Parent
            if (!(Test-Path $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            Copy-Item $_.FullName -Destination $targetPath -Force
        }
        Write-Host "  ✓ Copied resource files" -ForegroundColor Green
    }
}

Write-Host "`nDone!" -ForegroundColor Cyan

