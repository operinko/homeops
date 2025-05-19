$replicationSources = @(
    @{namespace = "default"; name = "atuin"},
    @{namespace = "media"; name = "bazarr"},
    @{namespace = "media"; name = "huntarr"},
    @{namespace = "media"; name = "prowlarr"},
    @{namespace = "media"; name = "radarr"},
    @{namespace = "media"; name = "recyclarr"},
    @{namespace = "media"; name = "sabnzbd"},
    @{namespace = "media"; name = "sonarr"},
    @{namespace = "media"; name = "spotarr"},
    @{namespace = "media"; name = "tautulli"},
    @{namespace = "media"; name = "wizarr"},
    @{namespace = "network"; name = "technitium"},
    @{namespace = "observability"; name = "gatus"},
    @{namespace = "security"; name = "vaultwarden"},
    @{namespace = "storage"; name = "minio"},
    @{namespace = "tools"; name = "headlamp"}
)

$patchJson = '{"spec":{"restic":{"volumeSnapshotClassName":"csi-democratic-snapshotclass","cacheStorageClassName":"democratic-volsync","storageClassName":"democratic-volsync"}}}'

foreach ($rs in $replicationSources) {
    Write-Host "Patching ReplicationSource $($rs.name) in namespace $($rs.namespace)..."
    kubectl patch replicationsource $rs.name -n $rs.namespace --type=merge -p $patchJson
}

Write-Host "All ReplicationSources have been updated to use democratic-csi."
