#!/usr/bin/env pwsh
# Migrate default namespace apps to ApplicationSet structure

$apps = @("atuin", "audiobookshelf", "echo", "homepage")

foreach ($app in $apps) {
    Write-Host "Processing $app..." -ForegroundColor Cyan
    
    # Create app directory
    $appDir = "kubernetes/argocd/applications/default/apps/$app"
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    
    # Create config.yaml
    $config = @"
---
# Configuration for $app application
# Used by ApplicationSet generator
app:
  name: $app
  chartVersion: "4.4.0"
  enabled: true
"@
    Set-Content -Path "$appDir/config.yaml" -Value $config
    
    # Extract Helm values from Application YAML
    $appYaml = "kubernetes/argocd/applications/default/$app.yaml"
    if (Test-Path $appYaml) {
        $content = Get-Content $appYaml -Raw
        
        # Extract values between "values: |" and the next source or destination
        if ($content -match '(?s)values: \|\s*\n(.*?)\n    # .*from git|(?s)values: \|\s*\n(.*?)\n  destination:') {
            $values = $matches[1]
            if (!$values) { $values = $matches[2] }
            
            # Remove leading 10 spaces from each line
            $values = $values -replace '(?m)^          ', ''
            
            # Create values.yaml
            $output = "---`n# Helm values for $app app-template deployment`n$values"
            Set-Content -Path "$appDir/values.yaml" -Value $output
            Write-Host "  ✓ Extracted values.yaml" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Could not extract values from $app" -ForegroundColor Yellow
        }
    }
    
    # Copy resource files from old directory
    $oldDir = "kubernetes/argocd/applications/default/$app"
    if (Test-Path $oldDir) {
        Get-ChildItem $oldDir -File | ForEach-Object {
            Copy-Item $_.FullName -Destination $appDir -Force
        }
        Write-Host "  ✓ Copied resource files" -ForegroundColor Green
    }
    
    # Copy resources subdirectory if it exists (for homepage)
    $resourcesDir = "$oldDir/resources"
    if (Test-Path $resourcesDir) {
        Copy-Item $resourcesDir -Destination $appDir -Recurse -Force
        Write-Host "  ✓ Copied resources directory" -ForegroundColor Green
    }
}

Write-Host "`nDone!" -ForegroundColor Cyan

