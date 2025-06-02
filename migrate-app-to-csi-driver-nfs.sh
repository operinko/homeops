#!/bin/bash

# Script to migrate an application from democratic-csi to csi-driver-nfs
# Usage: ./migrate-app-to-csi-driver-nfs.sh -n <namespace> -a <app> [-d]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NAMESPACE=""
APP=""
DELETE_PVCS=false
DRY_RUN=false

# Function to display usage
usage() {
    echo "Usage: $0 -n <namespace> -a <app> [-d] [--dry-run]"
    echo "  -n <namespace>  : Kubernetes namespace"
    echo "  -a <app>        : Application name"
    echo "  -d              : Delete existing PVCs (optional)"
    echo "  --dry-run       : Show what would be done without executing"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -a|--app)
            APP="$2"
            shift 2
            ;;
        -d|--delete-pvcs)
            DELETE_PVCS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$NAMESPACE" ] || [ -z "$APP" ]; then
    echo -e "${RED}Error: Namespace and app name are required${NC}"
    usage
fi

function write_step() {
    echo -e "${BLUE}➡️ $1${NC}"
}

function write_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

function write_warning() {
    echo -e "${YELLOW}⚠️ $1${NC}"
}

function write_error() {
    echo -e "${RED}❌ $1${NC}"
}

function execute_command() {
    local cmd="$1"
    local description="$2"
    
    write_step "$description"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}[DRY RUN] Would execute: $cmd${NC}"
        return 0
    fi
    
    if eval "$cmd"; then
        return 0
    else
        local exit_code=$?
        write_error "Command failed with exit code $exit_code"
        return $exit_code
    fi
}

echo -e "${BLUE}🚀 Starting migration of $APP in namespace $NAMESPACE to CSI-Driver-NFS${NC}"

# Step 1: Check if CSI-Driver-NFS is available
write_step "Checking if CSI-Driver-NFS storage class is available..."
if [ "$DRY_RUN" = false ]; then
    if ! kubectl get storageclass nfs-csi &>/dev/null; then
        write_error "CSI-Driver-NFS storage class 'nfs-csi' not found. Please deploy CSI-Driver-NFS first."
        exit 1
    fi
    write_success "CSI-Driver-NFS storage class found"
else
    write_warning "[DRY RUN] Assuming CSI-Driver-NFS is available"
fi

# Step 2: Create backup with current system
write_step "Creating backup with current democratic-csi system..."
execute_command "kubectl patch replicationsource $APP -n $NAMESPACE --type=merge -p '{\"spec\":{\"trigger\":{\"manual\":\"pre-migration-$(date +%Y%m%d%H%M%S)\"}}}'" "Triggering pre-migration backup"

# Step 3: Wait for backup to complete
if [ "$DRY_RUN" = false ]; then
    write_step "Waiting for backup to complete..."
    timeout 600 bash -c "
        while true; do
            status=\$(kubectl get replicationsource $APP -n $NAMESPACE -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo '')
            if [ ! -z \"\$status\" ]; then
                echo 'Backup completed at: '\$status
                break
            fi
            echo 'Waiting for backup to complete...'
            sleep 10
        done
    "
    write_success "Backup completed"
fi

# Step 4: Suspend application
execute_command "flux suspend kustomization $APP -n flux-system" "Suspending application Flux kustomization"
execute_command "kubectl scale deployment/$APP --replicas=0 -n $NAMESPACE 2>/dev/null || kubectl scale statefulset/$APP --replicas=0 -n $NAMESPACE 2>/dev/null || echo 'No deployment or statefulset to scale'" "Scaling down application"

# Step 5: Wait for pods to terminate
if [ "$DRY_RUN" = false ]; then
    write_step "Waiting for application pods to terminate..."
    kubectl wait pod --for=delete --selector="app.kubernetes.io/name=$APP" --timeout=300s -n $NAMESPACE || true
    write_success "Application pods terminated"
fi

# Step 6: Delete PVCs if requested
if [ "$DELETE_PVCS" = true ]; then
    execute_command "kubectl delete pvc $APP -n $NAMESPACE --ignore-not-found=true" "Deleting existing PVC"
fi

# Step 7: Resume application with new storage class
execute_command "flux resume kustomization $APP -n flux-system" "Resuming application Flux kustomization"

write_success "Migration completed! Application $APP should now be using CSI-Driver-NFS storage."
write_warning "Please verify the application is working correctly and that data is accessible."

echo -e "${GREEN}🎉 Migration of $APP to CSI-Driver-NFS completed successfully!${NC}"
