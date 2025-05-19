#!/usr/bin/env bash
# This script fixes a stuck VolSync snapshot
# Usage: ./unstick.sh <namespace> <app>

set -e

# Check arguments
if [ $# -lt 2 ]; then
  echo "Usage: $0 <namespace> <app>"
  exit 1
fi

NAMESPACE=$1
APP=$2

# Set colors for output
INFO='\033[0;36m'    # Cyan
SUCCESS='\033[0;32m' # Green
WARNING='\033[0;33m' # Yellow
ERROR='\033[0;31m'   # Red
NC='\033[0m'         # No Color

function write_step() {
  echo -e "${INFO}➡️ $1${NC}"
}

function write_success() {
  echo -e "${SUCCESS}✅ $1${NC}"
}

function write_warning() {
  echo -e "${WARNING}⚠️ $1${NC}"
}

function write_error() {
  echo -e "${ERROR}❌ $1${NC}"
}

# Step 1: Delete the ReplicationSource
write_step "Step 1: Deleting ReplicationSource $APP in namespace $NAMESPACE"
kubectl delete replicationsource $APP -n $NAMESPACE --ignore-not-found

# Step 2: Find and delete any stuck VolumeSnapshots
write_step "Step 2: Finding and deleting stuck VolumeSnapshots for $APP in namespace $NAMESPACE"
SNAPSHOTS=$(kubectl get volumesnapshot -n $NAMESPACE -l volsync.backube/app=$APP -o name 2>/dev/null || true)
if [ -n "$SNAPSHOTS" ]; then
  echo "Found snapshots: $SNAPSHOTS"
  for SNAPSHOT in $SNAPSHOTS; do
    echo "Deleting snapshot: $SNAPSHOT"
    kubectl delete $SNAPSHOT -n $NAMESPACE --ignore-not-found
  done
else
  write_warning "No VolumeSnapshots found for $APP in namespace $NAMESPACE"
fi

# Step 3: Find and delete any stuck VolumeSnapshotContents
write_step "Step 3: Finding and deleting stuck VolumeSnapshotContents for $APP"
SNAPSHOT_CONTENTS=$(kubectl get volumesnapshotcontent -l volsync.backube/app=$APP -o name 2>/dev/null || true)
if [ -n "$SNAPSHOT_CONTENTS" ]; then
  echo "Found snapshot contents: $SNAPSHOT_CONTENTS"
  for CONTENT in $SNAPSHOT_CONTENTS; do
    echo "Deleting snapshot content: $CONTENT"
    kubectl delete $CONTENT --ignore-not-found
  done
else
  write_warning "No VolumeSnapshotContents found for $APP"
fi

# Step 4: Reconcile the Kustomization
write_step "Step 4: Reconciling Kustomization $APP in namespace $NAMESPACE"
flux reconcile kustomization $APP -n $NAMESPACE || true

# Step 5: Wait for ReplicationSource to be recreated
write_step "Step 5: Waiting for ReplicationSource to be recreated (30 seconds)"
sleep 30

# Step 6: Manually trigger a new snapshot
write_step "Step 6: Manually triggering a new snapshot"
TIMESTAMP=$(date +%s)
kubectl -n $NAMESPACE patch replicationsource $APP --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$TIMESTAMP\"}}}" || true

write_success "Done! Check the status with: kubectl get replicationsource $APP -n $NAMESPACE"
