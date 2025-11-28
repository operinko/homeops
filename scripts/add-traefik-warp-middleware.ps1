#!/usr/bin/env pwsh
# Add traefik-warp middleware to all HTTPRoutes with authentik-forward

$files = @(
  "kubernetes/argocd/applications/tools/headlamp/httproute.yaml",
  "kubernetes/argocd/applications/observability/apps/grafana/httproute.yaml",
  "kubernetes/argocd/applications/observability/apps/goldilocks/httproute.yaml",
  "kubernetes/argocd/applications/observability/apps/gatus/httproute.yaml",
  "kubernetes/argocd/applications/network/apps/technitium/httproute.yaml",
  "kubernetes/argocd/applications/media/apps/spotarr/httproute.yaml",
  "kubernetes/argocd/applications/media/apps/sabnzbd/httproute.yaml",
  "kubernetes/argocd/applications/media/apps/readarr/httproute.yaml",
  "kubernetes/argocd/applications/media/apps/radarr/httproute.yaml",
  "kubernetes/argocd/applications/media/apps/prowlarr/httproute.yaml",
  "kubernetes/argocd/applications/media/apps/nzbget/httproute.yaml",
  "kubernetes/argocd/applications/media/apps/maintainerr/httproute.yaml",
  "kubernetes/argocd/applications/media/apps/huntarr/httproute.yaml",
  "kubernetes/argocd/applications/media/apps/bazarr/httproute.yaml",
  "kubernetes/argocd/applications/default/apps/audiobookshelf/httproute.yaml"
)

$warpMiddleware = @"
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: traefik-warp
"@

foreach ($file in $files) {
  if (Test-Path $file) {
    $content = Get-Content $file -Raw
    
    # Check if traefik-warp is already present
    if ($content -match "name: traefik-warp") {
      Write-Host "⏭️  Skipping $file (traefik-warp already present)"
      continue
    }
    
    # Check if authentik-forward is present
    if ($content -notmatch "name: authentik-forward") {
      Write-Host "⚠️  Skipping $file (no authentik-forward middleware found)"
      continue
    }
    
    # Insert traefik-warp before authentik-forward
    $pattern = '(      filters:\r?\n)(        - type: ExtensionRef\r?\n          extensionRef:\r?\n            group: traefik\.io\r?\n            kind: Middleware\r?\n            name: authentik-forward)'
    $replacement = "`$1$warpMiddleware`$2"
    
    $newContent = $content -replace $pattern, $replacement
    
    if ($newContent -ne $content) {
      Set-Content -Path $file -Value $newContent -NoNewline
      Write-Host "✅ Updated: $file"
    } else {
      Write-Host "⚠️  No changes made to: $file (pattern not matched)"
    }
  } else {
    Write-Host "❌ File not found: $file"
  }
}

Write-Host "`n✨ Done! Added traefik-warp middleware to HTTPRoutes."

