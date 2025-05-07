#!/bin/bash

# This script fixes a stuck VolSync snapshot
# Usage: ./unstuck.sh <namespace> <app>

NS=$1
APP=$2

if [ -z "$NS" ] || [ -z "$APP" ]; then
  echo "Usage: ./unstuck.sh <namespace> <app>"
  exit 1
fi

echo "Step 1: Deleting ReplicationSource ${APP} in namespace ${NS}"
kubectl delete replicationsource ${APP} -n ${NS} || true

echo "Step 2: Force deleting VolumeSnapshot volsync-${APP}-src in namespace ${NS}"
kubectl delete volumesnapshot volsync-${APP}-src -n ${NS} --force --grace-period=0 || true

echo "Step 3: Checking for VolumeSnapshotContent"
SNAPSHOT_CONTENT=$(kubectl get volumesnapshot volsync-${APP}-src -n ${NS} -o jsonpath='{.status.boundVolumeSnapshotContentName}' 2>/dev/null || echo "")
if [ -n "$SNAPSHOT_CONTENT" ]; then
  echo "Force deleting VolumeSnapshotContent $SNAPSHOT_CONTENT"
  kubectl delete volumesnapshotcontent $SNAPSHOT_CONTENT --force --grace-period=0 || true
else
  echo "No VolumeSnapshotContent found or already deleted"
fi

echo "Step 4: Reconciling Kustomization ${APP} in namespace ${NS}"
flux reconcile kustomization ${APP} -n ${NS} || true

echo "Step 5: Waiting for ReplicationSource to be recreated (30 seconds)"
sleep 30

echo "Step 6: Manually triggering a new snapshot"
TIMESTAMP=$(date +%s)
kubectl -n ${NS} patch replicationsources ${APP} --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$TIMESTAMP\"}}}" || true

echo "Done! Check the status with: kubectl get replicationsource ${APP} -n ${NS}"
