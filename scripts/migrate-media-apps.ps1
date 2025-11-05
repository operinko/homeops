#!/usr/bin/env pwsh
# Script to migrate media applications to ApplicationSet structure
# Extracts Helm values from Application YAML files and creates new directory structure

$apps = @(
    "configarr",
    "huntarr", 
    "prowlarr",
    "radarr",
    "readarr",
    "sabnzbd",
    "sonarr",
    "spotarr",
    "taggarr",
    "tautulli",
    "tvheadend",
    "wizarr"
)

$baseDir = "kubernetes/argocd/applications/media"
$appsDir = "$baseDir/apps"

foreach ($app in $apps) {
    Write-Host "Migrating $app..." -ForegroundColor Cyan
    
    # Create app directory
    $appDir = "$appsDir/$app"
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    
    # Copy resources from old directory to new
    $oldResourceDir = "$baseDir/$app"
    if (Test-Path $oldResourceDir) {
        Copy-Item -Path "$oldResourceDir/*" -Destination $appDir -Force
        Write-Host "  ✓ Copied resources from $oldResourceDir" -ForegroundColor Green
    }
    
    # Create config.yaml
    $configContent = @"
---
# Configuration for $app application
# Used by ApplicationSet generator
app:
  name: $app
  chartVersion: "4.4.0"
  enabled: true
"@
    Set-Content -Path "$appDir/config.yaml" -Value $configContent
    Write-Host "  ✓ Created config.yaml" -ForegroundColor Green
    
    # Extract Helm values from Application YAML
    $appYaml = "$baseDir/$app.yaml"
    if (Test-Path $appYaml) {
        $content = Get-Content $appYaml -Raw
        
        # Extract the valuesObject section using regex
        if ($content -match '(?s)valuesObject:\s*\n((?:[ ]{10}.+\n?)+)') {
            $valuesSection = $matches[1]
            
            # Remove the 10-space indentation to get proper YAML
            $values = $valuesSection -replace '(?m)^[ ]{10}', ''
            
            # Add YAML header
            $valuesContent = "---`n# Helm values for $app app-template deployment`n$values"
            
            Set-Content -Path "$appDir/values.yaml" -Value $valuesContent
            Write-Host "  ✓ Extracted values.yaml" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Could not extract values from $appYaml" -ForegroundColor Yellow
        }
    }
    
    Write-Host ""
}

Write-Host "Migration complete!" -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Review the generated values.yaml files"
Write-Host "2. Verify kustomization.yaml files in each app directory"
Write-Host "3. Remove old Application YAML files"
Write-Host "4. Add ApplicationSets to ArgoCD kustomization"

