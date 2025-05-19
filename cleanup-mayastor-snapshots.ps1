# Get all VolumeSnapshotContent resources that reference mayastor
$snapContents = kubectl get volumesnapshotcontent -o json | ConvertFrom-Json
$mayastorSnapContents = $snapContents.items | Where-Object { $_.spec.driver -eq "io.openebs.csi-mayastor" } | ForEach-Object { $_.metadata.name }

# Get all VolumeSnapshot resources that reference mayastor
$snapshots = kubectl get volumesnapshot --all-namespaces -o json | ConvertFrom-Json
$mayastorSnapshots = $snapshots.items | Where-Object { $_.spec.volumeSnapshotClassName -eq "csi-mayastor-snapshotclass" } | ForEach-Object { 
    [PSCustomObject]@{
        Name = $_.metadata.name
        Namespace = $_.metadata.namespace
    }
}

# Remove finalizers from VolumeSnapshotContent resources
Write-Host "Removing finalizers from VolumeSnapshotContent resources..."
foreach ($snapContent in $mayastorSnapContents) {
    Write-Host "Patching VolumeSnapshotContent $snapContent..."
    kubectl patch volumesnapshotcontent $snapContent -p '{"metadata":{"finalizers":null}}' --type=merge
}

# Remove finalizers from VolumeSnapshot resources
Write-Host "Removing finalizers from VolumeSnapshot resources..."
foreach ($snapshot in $mayastorSnapshots) {
    Write-Host "Patching VolumeSnapshot $($snapshot.Name) in namespace $($snapshot.Namespace)..."
    kubectl patch volumesnapshot $snapshot.Name -n $snapshot.Namespace -p '{"metadata":{"finalizers":null}}' --type=merge
}

# Delete VolumeSnapshotContent resources
Write-Host "Deleting VolumeSnapshotContent resources..."
foreach ($snapContent in $mayastorSnapContents) {
    Write-Host "Deleting VolumeSnapshotContent $snapContent..."
    kubectl delete volumesnapshotcontent $snapContent --force --grace-period=0
}

# Delete VolumeSnapshot resources
Write-Host "Deleting VolumeSnapshot resources..."
foreach ($snapshot in $mayastorSnapshots) {
    Write-Host "Deleting VolumeSnapshot $($snapshot.Name) in namespace $($snapshot.Namespace)..."
    kubectl delete volumesnapshot $snapshot.Name -n $snapshot.Namespace --force --grace-period=0
}

Write-Host "All mayastor snapshot resources have been cleaned up."
