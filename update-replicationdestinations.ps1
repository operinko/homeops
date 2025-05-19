$replicationDestinations = @(
    @{namespace = "default"; name = "atuin-dst"},
    @{namespace = "media"; name = "bazarr-dst"},
    @{namespace = "media"; name = "huntarr-dst"},
    @{namespace = "media"; name = "prowlarr-dst"},
    @{namespace = "media"; name = "radarr-dst"},
    @{namespace = "media"; name = "recyclarr-dst"},
    @{namespace = "media"; name = "sabnzbd-dst"},
    @{namespace = "media"; name = "sonarr-dst"},
    @{namespace = "media"; name = "spotarr-dst"},
    @{namespace = "media"; name = "tautulli-dst"},
    @{namespace = "media"; name = "wizarr-dst"},
    @{namespace = "network"; name = "technitium-dst"},
    @{namespace = "observability"; name = "gatus-dst"},
    @{namespace = "security"; name = "vaultwarden-dst"},
    @{namespace = "storage"; name = "minio-dst"},
    @{namespace = "tools"; name = "headlamp-dst"}
)

$patchJson = '{"spec":{"restic":{"volumeSnapshotClassName":"csi-democratic-snapshotclass","cacheStorageClassName":"democratic-volsync","storageClassName":"democratic-volsync"}}}'

foreach ($rd in $replicationDestinations) {
    Write-Host "Patching ReplicationDestination $($rd.name) in namespace $($rd.namespace)..."
    kubectl patch replicationdestination $rd.name -n $rd.namespace --type=merge -p $patchJson
}

Write-Host "All ReplicationDestinations have been updated to use democratic-csi."
