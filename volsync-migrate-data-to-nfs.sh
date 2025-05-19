#!/usr/bin/env bash
# This script migrates VolSync data from iSCSI to NFS storage classes.
# Usage: ./volsync-migrate-data-to-nfs.sh -n <namespace> -a <app> [-r]
# Where:
#   -n <namespace>: The namespace of the application to migrate
#   -a <app>: The name of the application to migrate
#   -r: Dry run mode (show what would be done without making changes)

set -e

# Default values
NAMESPACE=""
APP=""
DRY_RUN=false

# Parse command line arguments
while getopts "n:a:r" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    a) APP="$OPTARG" ;;
    r) DRY_RUN=true ;;
    *) echo "Usage: $0 -n <namespace> -a <app> [-r]" >&2
       exit 1 ;;
  esac
done

# Check required arguments
if [ -z "$NAMESPACE" ] || [ -z "$APP" ]; then
  echo "Error: Namespace (-n) and App (-a) are required arguments."
  echo "Usage: $0 -n <namespace> -a <app> [-r]"
  exit 1
fi

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

function execute_command() {
  local command="$1"
  local description="$2"

  write_step "$description"

  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${WARNING}[DRY RUN] Would execute: $command${NC}"
    return 0
  fi

  if eval "$command"; then
    return 0
  else
    local exit_code=$?
    write_error "Command failed with exit code $exit_code"
    return $exit_code
  fi
}

# Check if the application exists
write_step "Checking if application '$APP' exists in namespace '$NAMESPACE'..."
if ! execute_command "kubectl get deployment $APP -n $NAMESPACE -o name 2>/dev/null"; then
  # Try checking for statefulset
  if ! execute_command "kubectl get statefulset $APP -n $NAMESPACE -o name 2>/dev/null"; then
    write_warning "Application '$APP' not found in namespace '$NAMESPACE'. Continuing anyway as it might be using a different resource type."
  fi
fi

# Check if kustomization exists
write_step "Checking if kustomization '$APP' exists in namespace '$NAMESPACE'..."
if ! execute_command "flux get kustomization $APP -n $NAMESPACE 2>/dev/null"; then
  write_error "Kustomization '$APP' not found in namespace '$NAMESPACE'. Exiting."
  exit 1
fi

# Check if ReplicationSource exists
write_step "Checking for ReplicationSource '$APP' in namespace '$NAMESPACE'..."
REPLICATION_SOURCE_EXISTS=false
if kubectl get replicationsource $APP -n $NAMESPACE -o name &>/dev/null; then
  REPLICATION_SOURCE_EXISTS=true
  write_success "Found existing ReplicationSource '$APP' in namespace '$NAMESPACE'"
else
  write_warning "ReplicationSource '$APP' not found in namespace '$NAMESPACE'. Checking if PVC exists..."

  # Check if PVC exists
  if ! kubectl get pvc $APP -n $NAMESPACE -o name &>/dev/null; then
    write_error "Neither ReplicationSource nor PVC '$APP' found in namespace '$NAMESPACE'. Cannot migrate data. Exiting."
    exit 1
  fi

  write_success "Found PVC '$APP' in namespace '$NAMESPACE'. Will create a temporary ReplicationSource."

  # Get PVC details
  if [ "$DRY_RUN" = false ]; then
    PVC_STORAGE_CLASS=$(kubectl get pvc $APP -n $NAMESPACE -o jsonpath='{.spec.storageClassName}')
    PVC_ACCESS_MODES=$(kubectl get pvc $APP -n $NAMESPACE -o jsonpath='{.spec.accessModes}' | jq -c)
    PVC_CAPACITY=$(kubectl get pvc $APP -n $NAMESPACE -o jsonpath='{.spec.resources.requests.storage}')

    write_step "PVC Storage Class: $PVC_STORAGE_CLASS"
    write_step "PVC Access Modes: $PVC_ACCESS_MODES"
    write_step "PVC Capacity: $PVC_CAPACITY"
  else
    PVC_STORAGE_CLASS="democratic-volsync"
    PVC_ACCESS_MODES='["ReadWriteOnce"]'
    PVC_CAPACITY="10Gi"
  fi

  # Create a temporary ReplicationSource
  TEMP_SOURCE="${APP}-temp-source"

  cat <<EOF > temp-replicationsource.yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: ${TEMP_SOURCE}
  namespace: ${NAMESPACE}
spec:
  sourcePVC: "${APP}"
  trigger:
    manual: temp-source
  restic:
    copyMethod: Direct
    pruneIntervalDays: 14
    repository: "${APP}-volsync-secret"
    volumeSnapshotClassName: "csi-democratic-snapshotclass"
    cacheCapacity: "5Gi"
    cacheStorageClassName: "democratic-volsync"
    cacheAccessModes: ["ReadWriteOnce"]
    storageClassName: "${PVC_STORAGE_CLASS}"
    accessModes: ${PVC_ACCESS_MODES}
    moverSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
    retain:
      hourly: 24
      daily: 7
EOF

  if ! execute_command "kubectl apply -f temp-replicationsource.yaml" "Creating temporary ReplicationSource"; then
    write_error "Failed to create temporary ReplicationSource. Exiting."
    execute_command "rm -f temp-replicationsource.yaml" "Cleaning up temporary files"
    exit 1
  fi
  execute_command "rm -f temp-replicationsource.yaml" "Cleaning up temporary files"

  # Create the secret if it doesn't exist
  if ! kubectl get secret "${APP}-volsync-secret" -n $NAMESPACE &>/dev/null; then
    write_step "Creating temporary VolSync secret for '$APP' in namespace '$NAMESPACE'..."

    # Generate a random password
    RESTIC_PASSWORD=$(openssl rand -base64 32)

    cat <<EOF > temp-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: ${APP}-volsync-secret
  namespace: ${NAMESPACE}
stringData:
  RESTIC_REPOSITORY: /repository/${NAMESPACE}/${APP}
  RESTIC_PASSWORD: ${RESTIC_PASSWORD}
EOF

    if ! execute_command "kubectl apply -f temp-secret.yaml" "Creating temporary VolSync secret"; then
      write_warning "Failed to create temporary VolSync secret. Migration might fail."
    fi
    execute_command "rm -f temp-secret.yaml" "Cleaning up temporary files"
  fi
fi

# Step 1: Suspend the application's kustomization
if ! execute_command "flux suspend kustomization $APP -n $NAMESPACE" "Suspending kustomization '$APP' in namespace '$NAMESPACE'"; then
  write_error "Failed to suspend kustomization. Exiting."
  exit 1
fi
write_success "Kustomization suspended successfully"

# Step 2: Scale down the application
CONTROLLER_TYPE=$(kubectl get deployment $APP -n $NAMESPACE &>/dev/null && echo "deployment" || echo "statefulset")
if ! execute_command "kubectl scale $CONTROLLER_TYPE/$APP -n $NAMESPACE --replicas=0" "Scaling down $CONTROLLER_TYPE '$APP' in namespace '$NAMESPACE'"; then
  write_warning "Failed to scale down application. Continuing anyway..."
fi

# Step 3: Wait for pods to terminate
write_step "Waiting for pods to terminate..."
if [ "$DRY_RUN" = false ]; then
  kubectl wait pod --for=delete --selector="app.kubernetes.io/name=$APP" -n $NAMESPACE --timeout=5m || true
fi

# Step 4: Get information about the existing ReplicationSource or PVC
write_step "Getting information about the source..."
if [ "$DRY_RUN" = false ]; then
  if [ "$REPLICATION_SOURCE_EXISTS" = true ]; then
    # Get info from ReplicationSource
    SOURCE_PVC=$(kubectl get replicationsource $APP -n $NAMESPACE -o jsonpath='{.spec.sourcePVC}')
    ACCESS_MODES=$(kubectl get replicationsource $APP -n $NAMESPACE -o jsonpath='{.spec.restic.accessModes}')
    STORAGE_CLASS=$(kubectl get replicationsource $APP -n $NAMESPACE -o jsonpath='{.spec.restic.storageClassName}')
  else
    # Get info directly from PVC
    SOURCE_PVC="$APP"
    ACCESS_MODES=$(kubectl get pvc $APP -n $NAMESPACE -o jsonpath='{.spec.accessModes}' | jq -c)
    STORAGE_CLASS=$(kubectl get pvc $APP -n $NAMESPACE -o jsonpath='{.spec.storageClassName}')
  fi

  # Get capacity from PVC
  CAPACITY=$(kubectl get pvc $SOURCE_PVC -n $NAMESPACE -o jsonpath='{.spec.resources.requests.storage}')

  write_step "Source PVC: $SOURCE_PVC"
  write_step "Access Modes: $ACCESS_MODES"
  write_step "Storage Class: $STORAGE_CLASS"
  write_step "Capacity: $CAPACITY"
else
  SOURCE_PVC="$APP"
  ACCESS_MODES='["ReadWriteOnce"]'
  STORAGE_CLASS="democratic-volsync"
  CAPACITY="10Gi"
fi

# Step 5: Create a temporary ReplicationDestination on NFS
TEMP_DEST="${APP}-nfs-migration"
TEMP_PVC="${APP}-nfs"

cat <<EOF > temp-replicationdestination.yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: ${TEMP_DEST}
  namespace: ${NAMESPACE}
spec:
  trigger:
    manual: migrate-to-nfs
  restic:
    repository: "${APP}-volsync-secret"
    copyMethod: Direct
    storageClassName: "democratic-volsync-nfs"
    accessModes: ${ACCESS_MODES}
    capacity: "${CAPACITY}"
    moverSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
    enableFileDeletion: true
    cleanupCachePVC: true
    cleanupTempPVC: true
EOF

if ! execute_command "kubectl apply -f temp-replicationdestination.yaml" "Creating temporary ReplicationDestination on NFS"; then
  write_error "Failed to create temporary ReplicationDestination. Exiting."
  execute_command "rm -f temp-replicationdestination.yaml" "Cleaning up temporary files"
  execute_command "flux resume kustomization $APP -n $NAMESPACE" "Resuming kustomization"
  exit 1
fi
execute_command "rm -f temp-replicationdestination.yaml" "Cleaning up temporary files"

# Step 6: Trigger a manual snapshot from the source to the destination
TIMESTAMP=$(date +%s)
SOURCE_NAME=$APP
if [ "$REPLICATION_SOURCE_EXISTS" = false ]; then
  SOURCE_NAME=$TEMP_SOURCE
fi

if ! execute_command "kubectl -n $NAMESPACE patch replicationsource $SOURCE_NAME --type merge -p '{\"spec\":{\"trigger\":{\"manual\":\"$TIMESTAMP\"}}}'" "Triggering manual snapshot"; then
  write_error "Failed to trigger manual snapshot. Exiting."
  execute_command "kubectl delete replicationdestination $TEMP_DEST -n $NAMESPACE" "Cleaning up temporary ReplicationDestination"
  if [ "$REPLICATION_SOURCE_EXISTS" = false ]; then
    execute_command "kubectl delete replicationsource $TEMP_SOURCE -n $NAMESPACE" "Cleaning up temporary ReplicationSource"
  fi
  execute_command "flux resume kustomization $APP -n $NAMESPACE" "Resuming kustomization"
  exit 1
fi

# Step 7: Wait for the snapshot job to complete
write_step "Waiting for snapshot job to complete..."
if [ "$DRY_RUN" = false ]; then
  # Wait for the job to be created
  JOB_NAME="volsync-src-$SOURCE_NAME"
  COUNTER=0
  MAX_RETRIES=12
  while ! kubectl get job $JOB_NAME -n $NAMESPACE &>/dev/null; do
    COUNTER=$((COUNTER+1))
    if [ $COUNTER -ge $MAX_RETRIES ]; then
      write_error "Timed out waiting for snapshot job to be created. Exiting."
      execute_command "kubectl delete replicationdestination $TEMP_DEST -n $NAMESPACE" "Cleaning up temporary ReplicationDestination"
      if [ "$REPLICATION_SOURCE_EXISTS" = false ]; then
        execute_command "kubectl delete replicationsource $TEMP_SOURCE -n $NAMESPACE" "Cleaning up temporary ReplicationSource"
      fi
      execute_command "flux resume kustomization $APP -n $NAMESPACE" "Resuming kustomization"
      exit 1
    fi
    echo "Waiting for snapshot job to be created... ($COUNTER/$MAX_RETRIES)"
    sleep 10
  done

  # Wait for the job to complete
  if ! kubectl wait job/$JOB_NAME -n $NAMESPACE --for=condition=complete --timeout=30m; then
    write_error "Snapshot job failed or timed out. Exiting."
    execute_command "kubectl delete replicationdestination $TEMP_DEST -n $NAMESPACE" "Cleaning up temporary ReplicationDestination"
    if [ "$REPLICATION_SOURCE_EXISTS" = false ]; then
      execute_command "kubectl delete replicationsource $TEMP_SOURCE -n $NAMESPACE" "Cleaning up temporary ReplicationSource"
    fi
    execute_command "flux resume kustomization $APP -n $NAMESPACE" "Resuming kustomization"
    exit 1
  fi
fi
write_success "Snapshot completed successfully"

# Step 8: Create a PVC from the ReplicationDestination
cat <<EOF > temp-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TEMP_PVC}
  namespace: ${NAMESPACE}
spec:
  accessModes: ${ACCESS_MODES}
  dataSourceRef:
    kind: ReplicationDestination
    apiGroup: volsync.backube
    name: ${TEMP_DEST}
  resources:
    requests:
      storage: ${CAPACITY}
  storageClassName: "democratic-volsync-nfs"
EOF

if ! execute_command "kubectl apply -f temp-pvc.yaml" "Creating PVC from ReplicationDestination"; then
  write_error "Failed to create PVC from ReplicationDestination. Exiting."
  execute_command "rm -f temp-pvc.yaml" "Cleaning up temporary files"
  execute_command "kubectl delete replicationdestination $TEMP_DEST -n $NAMESPACE" "Cleaning up temporary ReplicationDestination"
  execute_command "flux resume kustomization $APP -n $NAMESPACE" "Resuming kustomization"
  exit 1
fi
execute_command "rm -f temp-pvc.yaml" "Cleaning up temporary files"

# Step 9: Delete the ReplicationSource and ReplicationDestination
if [ "$REPLICATION_SOURCE_EXISTS" = true ]; then
  execute_command "kubectl delete replicationsource $APP -n $NAMESPACE --ignore-not-found" "Deleting original ReplicationSource"
else
  execute_command "kubectl delete replicationsource $TEMP_SOURCE -n $NAMESPACE --ignore-not-found" "Deleting temporary ReplicationSource"
fi
execute_command "kubectl delete replicationdestination $APP-dst -n $NAMESPACE --ignore-not-found" "Deleting original ReplicationDestination"

# Step 10: Delete the temporary ReplicationDestination
execute_command "kubectl delete replicationdestination $TEMP_DEST -n $NAMESPACE --ignore-not-found" "Deleting temporary ReplicationDestination"

# Step 11: Rename the new PVC to replace the original
if ! execute_command "kubectl get pvc $SOURCE_PVC -n $NAMESPACE -o yaml > original-pvc.yaml" "Backing up original PVC definition"; then
  write_warning "Failed to backup original PVC. Continuing anyway..."
fi

if ! execute_command "kubectl delete pvc $SOURCE_PVC -n $NAMESPACE --ignore-not-found" "Deleting original PVC"; then
  write_warning "Failed to delete original PVC. Continuing anyway..."
fi

if ! execute_command "kubectl patch pvc $TEMP_PVC -n $NAMESPACE -p '{\"metadata\":{\"name\":\"$SOURCE_PVC\"}}' --type=merge" "Renaming new PVC"; then
  write_error "Failed to rename new PVC. You may need to manually rename it from $TEMP_PVC to $SOURCE_PVC."
  write_warning "Resuming kustomization anyway..."
fi

# Step 12: Resume the application's kustomization
if ! execute_command "flux resume kustomization $APP -n $NAMESPACE" "Resuming kustomization '$APP' in namespace '$NAMESPACE'"; then
  write_error "Failed to resume kustomization. Please check the status and resume manually."
  exit 1
fi
write_success "Kustomization resumed successfully"

# Step 13: Trigger reconciliation
if ! execute_command "flux reconcile kustomization $APP -n $NAMESPACE" "Triggering reconciliation for kustomization '$APP' in namespace '$NAMESPACE'"; then
  write_warning "Failed to trigger reconciliation. The kustomization will reconcile based on its configured interval."
else
  write_success "Reconciliation triggered successfully"
fi

write_success "Data migration process completed for '$APP' in namespace '$NAMESPACE'"
echo "You can check the status with: flux get kustomization $APP -n $NAMESPACE"
echo "And monitor the VolSync resources with: kubectl get replicationsource,replicationdestination -n $NAMESPACE"
