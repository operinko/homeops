#!/usr/bin/env pwsh
# Extract Helm values from Application YAML files

$apps = @(
    "configarr", "huntarr", "prowlarr", "radarr", "readarr",
    "sabnzbd", "sonarr", "spotarr", "taggarr", "tautulli",
    "tvheadend", "wizarr"
)

foreach ($app in $apps) {
    $appYaml = "kubernetes/argocd/applications/media/$app.yaml"
    $valuesYaml = "kubernetes/argocd/applications/media/apps/$app/values.yaml"
    
    if (!(Test-Path $appYaml)) {
        Write-Host "⚠ $appYaml not found" -ForegroundColor Yellow
        continue
    }
    
    $content = Get-Content $appYaml -Raw
    
    # Extract everything between "valuesObject:" and "  destination:"
    if ($content -match '(?s)valuesObject:\s*\n(.*?)\n  destination:') {
        $values = $matches[1]
        
        # Remove the leading 8 spaces from each line (indentation from Application spec)
        $values = $values -replace '(?m)^        ', ''
        
        # Create values.yaml with header
        $output = "---`n# Helm values for $app app-template deployment`n$values"
        
        Set-Content -Path $valuesYaml -Value $output
        Write-Host "✓ $app" -ForegroundColor Green
    } else {
        Write-Host "⚠ Could not extract values from $app" -ForegroundColor Yellow
    }
}

Write-Host "`nDone!" -ForegroundColor Cyan

