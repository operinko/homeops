#!/usr/bin/env bash
# This script migrates VolSync resources from iSCSI to NFS storage classes.
# Usage: ./volsync-migrate-to-nfs.sh -n <namespace> -a <app> [-d] [-r]
# Where:
#   -n <namespace>: The namespace of the application to migrate
#   -a <app>: The name of the application to migrate
#   -d: Delete PVCs related to the application
#   -r: Dry run mode (show what would be done without making changes)

set -e

# Default values
NAMESPACE=""
APP=""
DELETE_PVCS=false
DRY_RUN=false

# Parse command line arguments
while getopts "n:a:dr" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    a) APP="$OPTARG" ;;
    d) DELETE_PVCS=true ;;
    r) DRY_RUN=true ;;
    *) echo "Usage: $0 -n <namespace> -a <app> [-d] [-r]" >&2
       exit 1 ;;
  esac
done

# Check required arguments
if [ -z "$NAMESPACE" ] || [ -z "$APP" ]; then
  echo "Error: Namespace (-n) and App (-a) are required arguments."
  echo "Usage: $0 -n <namespace> -a <app> [-d] [-r]"
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

# Step 1: Suspend the application's kustomization
if ! execute_command "flux suspend kustomization $APP -n $NAMESPACE" "Suspending kustomization '$APP' in namespace '$NAMESPACE'"; then
  write_error "Failed to suspend kustomization. Exiting."
  exit 1
fi
write_success "Kustomization suspended successfully"

# Step 2: Delete the ReplicationSource if it exists
write_step "Checking for ReplicationSource '$APP' in namespace '$NAMESPACE'..."
if kubectl get replicationsource $APP -n $NAMESPACE -o name 2>/dev/null; then
  if execute_command "kubectl delete replicationsource $APP -n $NAMESPACE" "Deleting ReplicationSource '$APP' in namespace '$NAMESPACE'"; then
    write_success "ReplicationSource deleted successfully"
  else
    write_warning "Failed to delete ReplicationSource. Continuing..."
  fi
else
  write_warning "ReplicationSource '$APP' not found in namespace '$NAMESPACE'. Skipping deletion."
fi

# Step 3: Delete the ReplicationDestination if it exists
write_step "Checking for ReplicationDestination '$APP-dst' in namespace '$NAMESPACE'..."
if kubectl get replicationdestination $APP-dst -n $NAMESPACE -o name 2>/dev/null; then
  if execute_command "kubectl delete replicationdestination $APP-dst -n $NAMESPACE" "Deleting ReplicationDestination '$APP-dst' in namespace '$NAMESPACE'"; then
    write_success "ReplicationDestination deleted successfully"
  else
    write_warning "Failed to delete ReplicationDestination. Continuing..."
  fi
else
  write_warning "ReplicationDestination '$APP-dst' not found in namespace '$NAMESPACE'. Skipping deletion."
fi

# Step 4: Delete PVCs if requested
if [ "$DELETE_PVCS" = true ]; then
  write_step "Checking for PVC '$APP' in namespace '$NAMESPACE'..."
  if kubectl get pvc $APP -n $NAMESPACE -o name 2>/dev/null; then
    if execute_command "kubectl delete pvc $APP -n $NAMESPACE" "Deleting PVC '$APP' in namespace '$NAMESPACE'"; then
      write_success "PVC deleted successfully"
    else
      write_warning "Failed to delete PVC. Continuing..."
    fi
  else
    write_warning "PVC '$APP' not found in namespace '$NAMESPACE'. Skipping deletion."
  fi
  
  # Check for cache PVCs
  write_step "Checking for cache PVCs related to '$APP' in namespace '$NAMESPACE'..."
  CACHE_PVCS=$(kubectl get pvc -n $NAMESPACE -l volsync.backube/app=$APP -o name 2>/dev/null)
  if [ -n "$CACHE_PVCS" ]; then
    if execute_command "kubectl delete pvc -n $NAMESPACE -l volsync.backube/app=$APP" "Deleting cache PVCs for '$APP' in namespace '$NAMESPACE'"; then
      write_success "Cache PVCs deleted successfully"
    else
      write_warning "Failed to delete cache PVCs. Continuing..."
    fi
  else
    write_warning "No cache PVCs found for '$APP' in namespace '$NAMESPACE'. Skipping deletion."
  fi
fi

# Step 5: Resume the application's kustomization
if ! execute_command "flux resume kustomization $APP -n $NAMESPACE" "Resuming kustomization '$APP' in namespace '$NAMESPACE'"; then
  write_error "Failed to resume kustomization. Please check the status and resume manually."
  exit 1
fi
write_success "Kustomization resumed successfully"

# Step 6: Trigger reconciliation
if ! execute_command "flux reconcile kustomization $APP -n $NAMESPACE" "Triggering reconciliation for kustomization '$APP' in namespace '$NAMESPACE'"; then
  write_warning "Failed to trigger reconciliation. The kustomization will reconcile based on its configured interval."
else
  write_success "Reconciliation triggered successfully"
fi

write_success "Migration process completed for '$APP' in namespace '$NAMESPACE'"
echo "You can check the status with: flux get kustomization $APP -n $NAMESPACE"
echo "And monitor the VolSync resources with: kubectl get replicationsource,replicationdestination -n $NAMESPACE"
