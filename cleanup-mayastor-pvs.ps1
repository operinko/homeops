$pvs = kubectl get pv | Select-String -Pattern "mayastor" | ForEach-Object { $_.ToString().Split()[0] }

foreach ($pv in $pvs) {
    Write-Host "Patching PV $pv to remove finalizers..."
    kubectl patch pv $pv -p '{"metadata":{"finalizers":null}}'
}

Write-Host "All mayastor PVs have been patched to remove finalizers."
