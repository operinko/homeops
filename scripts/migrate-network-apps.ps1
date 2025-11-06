#!/usr/bin/env pwsh
# Migrate network namespace apps to ApplicationSet structure

$apps = @(
    @{name="cloudflare-dns"; chart="external-dns"; repo="https://kubernetes-sigs.github.io/external-dns"; version="1.19.0"},
    @{name="cloudflare-tunnel"; chart="app-template"; repo="https://bjw-s-labs.github.io/helm-charts"; version="4.4.0"},
    @{name="crowdsec"; chart="crowdsec"; repo="https://crowdsecurity.github.io/helm-charts"; version="0.20.1"},
    @{name="internal-dns"; chart="external-dns"; repo="https://kubernetes-sigs.github.io/external-dns"; version="1.19.0"},
    @{name="technitium"; chart="app-template"; repo="https://bjw-s-labs.github.io/helm-charts"; version="4.4.0"}
)

foreach ($app in $apps) {
    $appName = $app.name
    Write-Host "Processing $appName..." -ForegroundColor Cyan
    
    # Create app directory
    $appDir = "kubernetes/argocd/applications/network/apps/$appName"
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
    $appYaml = "kubernetes/argocd/applications/network/$appName.yaml"
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
    
    # Copy resource files from old directory
    $oldDir = "kubernetes/argocd/applications/network/$appName"
    if (Test-Path $oldDir) {
        Get-ChildItem $oldDir -File | ForEach-Object {
            Copy-Item $_.FullName -Destination $appDir -Force
        }
        Write-Host "  ✓ Copied resource files" -ForegroundColor Green
    }
}

Write-Host "`nDone!" -ForegroundColor Cyan

