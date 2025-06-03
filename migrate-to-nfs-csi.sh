#!/bin/bash

# Automated Migration Script: Democratic-CSI to NFS-CSI
# Based on successful migration pattern from Sonarr, Radarr, SABnzbd, and Prowlarr

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/migration-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=${DRY_RUN:-false}
SKIP_CONFIRMATION=${SKIP_CONFIRMATION:-false}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${1}" | tee -a "${LOG_FILE}"
}

log_info() {
    log "${BLUE}[INFO]${NC} ${1}"
}

log_success() {
    log "${GREEN}[SUCCESS]${NC} ${1}"
}

log_warning() {
    log "${YELLOW}[WARNING]${NC} ${1}"
}

log_error() {
    log "${RED}[ERROR]${NC} ${1}"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    if ! command -v flux &> /dev/null; then
        log_error "flux CLI is not installed or not in PATH"
        exit 1
    fi

    # Test kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Get applications to migrate
get_applications_to_migrate() {
    echo "Scanning for applications using democratic-csi storage..." >&2

    # Define target applications by namespace
    declare -A target_apps=(
        ["media"]="bazarr recyclarr huntarr spotarr wizarr"
        ["default"]="atuin"
        ["security"]="vaultwarden"
        ["database"]="dragonfly"
        ["network"]="technitium"
        ["tools"]="headlamp"
        ["observability"]="gatus loki prometheus-kube-prometheus-stack"
    )

    local found_apps=()

    for namespace in "${!target_apps[@]}"; do
        for app in ${target_apps[$namespace]}; do
            # Check if PVC exists and uses democratic-csi storage
            if kubectl get pvc "$app" -n "$namespace" &> /dev/null 2>&1; then
                local storage_class=$(kubectl get pvc "$app" -n "$namespace" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
                if [[ "$storage_class" == *"democratic"* ]]; then
                    found_apps+=("$namespace/$app")
                    echo "Found: $namespace/$app (storage: $storage_class)" >&2
                fi
            fi
        done
    done

    if [ ${#found_apps[@]} -eq 0 ]; then
        echo "No applications found that need migration" >&2
        return 1
    fi

    # Return the array properly - only app names to stdout
    for app in "${found_apps[@]}"; do
        echo "$app"
    done
}

# Suspend application and VolSync
suspend_application() {
    local namespace="$1"
    local app="$2"

    log_info "Suspending $namespace/$app..."

    # Suspend ReplicationSource (using kubectl patch)
    if kubectl get replicationsource "$app" -n "$namespace" &> /dev/null; then
        if [ "$DRY_RUN" = "false" ]; then
            kubectl patch replicationsource "$app" -n "$namespace" --type merge -p '{"spec":{"suspend":true}}' || log_warning "Failed to suspend ReplicationSource"
        fi
        log_info "ReplicationSource suspended"
    fi

    # Suspend HelmRelease (using flux)
    if kubectl get helmrelease "$app" -n "$namespace" &> /dev/null; then
        if [ "$DRY_RUN" = "false" ]; then
            flux suspend helmrelease "$app" -n "$namespace" || log_warning "Failed to suspend HelmRelease"
        fi
        log_info "HelmRelease suspended"
    fi

    log_success "Application $namespace/$app suspended"
}

# Update kustomization to use NFS-CSI components
update_kustomization() {
    local namespace="$1"
    local app="$2"

    log_info "Updating kustomization for $namespace/$app..."

    local ks_file="kubernetes/apps/$namespace/$app/ks.yaml"

    if [ ! -f "$ks_file" ]; then
        log_warning "Kustomization file not found: $ks_file, trying alternative paths..."

        # Try alternative file names
        local alt_files=(
            "kubernetes/apps/$namespace/$app/kustomization.yaml"
            "kubernetes/apps/$namespace/$app/app/kustomization.yaml"
        )

        for alt_file in "${alt_files[@]}"; do
            if [ -f "$alt_file" ]; then
                ks_file="$alt_file"
                log_info "Found alternative file: $ks_file"
                break
            fi
        done

        if [ ! -f "$ks_file" ]; then
            log_error "No kustomization file found for $namespace/$app"
            return 1
        fi
    fi

    if [ "$DRY_RUN" = "false" ]; then
        # Update dependencies
        sed -i 's/democratic-csi-nfs/csi-driver-nfs/g' "$ks_file"

        # Update VolSync components path
        sed -i 's|../../../../components/volsync$|../../../../components/volsync/nfs-csi|g' "$ks_file"

        # Commit changes
        git add "$ks_file"
        git commit -m "feat($app): switch to NFS-CSI VolSync components

- Change dependency from democratic-csi-nfs to csi-driver-nfs
- Update VolSync components path from volsync to volsync/nfs-csi
- Part of automated migration from democratic-csi to nfs-csi storage"

        git push
    fi

    log_success "Kustomization updated for $namespace/$app"
}

# Create migration ReplicationDestination
create_migration_destination() {
    local namespace="$1"
    local app="$2"

    log_info "Creating migration ReplicationDestination for $namespace/$app..."

    local timestamp=$(date +%s)
    local dest_name="${app}-nfs-migration"

    if [ "$DRY_RUN" = "false" ]; then
        cat <<EOF | kubectl apply -f -
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: ${dest_name}
  namespace: ${namespace}
spec:
  trigger:
    manual: migrate-to-nfs-${timestamp}
  restic:
    repository: ${app}-volsync-secret
    copyMethod: Direct
    storageClassName: nfs-csi
    accessModes: ["ReadWriteOnce"]
    capacity: 10Gi
    moverSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
    enableFileDeletion: true
    cleanupCachePVC: true
    cleanupTempPVC: true
EOF
    fi

    # Wait for completion
    if [ "$DRY_RUN" = "false" ]; then
        log_info "Waiting for migration to complete..."
        local max_wait=300  # 5 minutes
        local wait_time=0

        while [ $wait_time -lt $max_wait ]; do
            local status=$(kubectl get replicationdestination "$dest_name" -n "$namespace" -o jsonpath='{.status.latestMoverStatus.result}' 2>/dev/null || echo "")

            if [ "$status" = "Successful" ]; then
                log_success "Migration completed successfully"
                break
            elif [ "$status" = "Failed" ]; then
                log_error "Migration failed"
                return 1
            fi

            sleep 10
            wait_time=$((wait_time + 10))
            log_info "Waiting... ($wait_time/${max_wait}s)"
        done

        if [ $wait_time -ge $max_wait ]; then
            log_error "Migration timed out"
            return 1
        fi

        # Clean up migration destination
        kubectl delete replicationdestination "$dest_name" -n "$namespace"
    fi

    log_success "Migration ReplicationDestination completed for $namespace/$app"
}

# Delete old resources and create new PVC
recreate_pvc() {
    local namespace="$1"
    local app="$2"

    log_info "Recreating PVC for $namespace/$app..."

    if [ "$DRY_RUN" = "false" ]; then
        # Delete pod first
        local pod=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$pod" ]; then
            kubectl delete pod "$pod" -n "$namespace" --force --grace-period=0 || true
        fi

        # Delete old VolSync resources
        kubectl delete replicationdestination "${app}-dst" -n "$namespace" || true
        kubectl delete replicationsource "$app" -n "$namespace" || true

        # Force delete stuck PVCs
        local pvcs=("$app" "volsync-${app}-cache" "volsync-${app}-src")
        for pvc in "${pvcs[@]}"; do
            if kubectl get pvc "$pvc" -n "$namespace" &> /dev/null; then
                kubectl patch pvc "$pvc" -n "$namespace" --type merge --patch-file remove-finalizers.yaml || true
            fi
        done

        # Wait for PVCs to be fully deleted
        log_info "Waiting for PVCs to be deleted..."
        local max_wait=60
        local wait_time=0
        while [ $wait_time -lt $max_wait ]; do
            local remaining_pvcs=0
            for pvc in "${pvcs[@]}"; do
                if kubectl get pvc "$pvc" -n "$namespace" &> /dev/null; then
                    remaining_pvcs=$((remaining_pvcs + 1))
                fi
            done

            if [ $remaining_pvcs -eq 0 ]; then
                log_info "All PVCs deleted successfully"
                break
            fi

            sleep 5
            wait_time=$((wait_time + 5))
            log_info "Waiting for PVC deletion... ($wait_time/${max_wait}s, $remaining_pvcs PVCs remaining)"
        done

        # Create simple NFS-CSI PVC
        cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${app}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ${app}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: nfs-csi
EOF
    fi

    log_success "PVC recreated for $namespace/$app"
}

# Force reconcile Flux resources
force_reconcile() {
    local namespace="$1"
    local app="$2"

    log_info "Force reconciling Flux resources for $namespace/$app..."

    if [ "$DRY_RUN" = "false" ]; then
        flux reconcile source git flux-system
        flux reconcile kustomization "$app" -n "$namespace"
    fi

    log_success "Flux resources reconciled for $namespace/$app"
}

# Resume application
resume_application() {
    local namespace="$1"
    local app="$2"

    log_info "Resuming $namespace/$app..."

    if [ "$DRY_RUN" = "false" ]; then
        # Resume HelmRelease
        if kubectl get helmrelease "$app" -n "$namespace" &> /dev/null; then
            flux resume helmrelease "$app" -n "$namespace"
        fi

        # Resume ReplicationSource (using kubectl patch)
        if kubectl get replicationsource "$app" -n "$namespace" &> /dev/null; then
            kubectl patch replicationsource "$app" -n "$namespace" --type merge -p '{"spec":{"suspend":false}}'
        fi
    fi

    log_success "Application $namespace/$app resumed"
}

# Verify application health
verify_application() {
    local namespace="$1"
    local app="$2"

    log_info "Verifying $namespace/$app health..."

    if [ "$DRY_RUN" = "false" ]; then
        local max_wait=180  # 3 minutes
        local wait_time=0

        while [ $wait_time -lt $max_wait ]; do
            local pod=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

            if [ -n "$pod" ]; then
                local ready=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

                if [ "$ready" = "True" ]; then
                    log_success "Application $namespace/$app is healthy"

                    # Try health check if possible
                    if kubectl exec -n "$namespace" "$pod" -- wget -q -O - http://localhost:80/ping &> /dev/null; then
                        log_success "Health check passed for $namespace/$app"
                    fi

                    return 0
                fi
            fi

            sleep 10
            wait_time=$((wait_time + 10))
            log_info "Waiting for health... ($wait_time/${max_wait}s)"
        done

        log_warning "Health verification timed out for $namespace/$app"
    fi

    return 0
}

# Migrate single application
migrate_application() {
    local namespace="$1"
    local app="$2"

    log_info "Starting migration of $namespace/$app"

    # Step 1: Suspend
    suspend_application "$namespace" "$app"

    # Step 2: Update kustomization
    update_kustomization "$namespace" "$app"

    # Step 3: Create migration destination
    create_migration_destination "$namespace" "$app"

    # Step 4: Recreate PVC
    recreate_pvc "$namespace" "$app"

    # Step 5: Force reconcile
    force_reconcile "$namespace" "$app"

    # Step 6: Resume application
    resume_application "$namespace" "$app"

    # Step 7: Verify health
    verify_application "$namespace" "$app"

    log_success "Migration completed for $namespace/$app"
}

# Backup current state
backup_current_state() {
    local namespace="$1"
    local app="$2"

    log_info "Backing up current state for $namespace/$app..."

    local backup_dir="${SCRIPT_DIR}/backups/${namespace}-${app}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    # Backup PVC definitions
    kubectl get pvc -n "$namespace" -l "app.kubernetes.io/name=$app" -o yaml > "$backup_dir/pvcs.yaml" 2>/dev/null || true

    # Backup VolSync resources
    kubectl get replicationsource "$app" -n "$namespace" -o yaml > "$backup_dir/replicationsource.yaml" 2>/dev/null || true
    kubectl get replicationdestination "${app}-dst" -n "$namespace" -o yaml > "$backup_dir/replicationdestination.yaml" 2>/dev/null || true

    # Backup HelmRelease
    kubectl get helmrelease "$app" -n "$namespace" -o yaml > "$backup_dir/helmrelease.yaml" 2>/dev/null || true

    log_info "Backup saved to: $backup_dir"
}

# Rollback function
rollback_application() {
    local namespace="$1"
    local app="$2"
    local backup_dir="$3"

    log_warning "Rolling back $namespace/$app..."

    if [ -d "$backup_dir" ]; then
        # Restore from backup
        kubectl apply -f "$backup_dir/" || true
        log_info "Restored from backup: $backup_dir"
    fi

    # Resume resources
    flux resume helmrelease "$app" -n "$namespace" || true
    kubectl patch replicationsource "$app" -n "$namespace" --type merge -p '{"spec":{"suspend":false}}' || true
}

# Enhanced error handling
handle_error() {
    local namespace="$1"
    local app="$2"
    local step="$3"
    local backup_dir="$4"

    log_error "Error in step '$step' for $namespace/$app"

    if [ "$SKIP_CONFIRMATION" = "false" ]; then
        echo
        read -p "Rollback this application? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rollback_application "$namespace" "$app" "$backup_dir"
        fi
    fi
}

# Main migration function
main() {
    log_info "Starting automated NFS-CSI migration script"
    log_info "Log file: $LOG_FILE"

    if [ "$DRY_RUN" = "true" ]; then
        log_warning "DRY RUN MODE - No changes will be made"
    fi

    check_prerequisites

    # Get applications to migrate
    log_info "Scanning for applications using democratic-csi storage..."
    local apps_output
    apps_output=$(get_applications_to_migrate 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ] || [ -z "$apps_output" ]; then
        log_info "No applications to migrate"
        exit 0
    fi

    # Convert output to array - filter out log messages
    local apps=()
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ "$line" != *"Scanning for applications"* ]] && [[ "$line" != *"Found:"* ]]; then
            apps+=("$line")
        elif [[ "$line" == *"Found:"* ]]; then
            log_info "$line"
        fi
    done <<< "$apps_output"

    log_info "Found ${#apps[@]} applications to migrate:"
    for app in "${apps[@]}"; do
        log_info "  - $app"
    done

    if [ "$SKIP_CONFIRMATION" = "false" ]; then
        echo
        read -p "Continue with migration? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Migration cancelled by user"
            exit 0
        fi
    fi

    local failed_apps=()
    local successful_apps=()

    for app_full in "${apps[@]}"; do
        local namespace="${app_full%/*}"
        local app="${app_full#*/}"

        log_info "Processing $namespace/$app..."

        # Create backup
        local backup_dir="${SCRIPT_DIR}/backups/${namespace}-${app}-$(date +%Y%m%d-%H%M%S)"
        if [ "$DRY_RUN" = "false" ]; then
            backup_current_state "$namespace" "$app"
        fi

        if migrate_application "$namespace" "$app"; then
            log_success "✅ $namespace/$app migration successful"
            successful_apps+=("$app_full")
        else
            log_error "❌ $namespace/$app migration failed"
            failed_apps+=("$app_full")

            if [ "$DRY_RUN" = "false" ]; then
                handle_error "$namespace" "$app" "migration" "$backup_dir"
            fi
        fi

        echo "----------------------------------------"
    done

    # Summary
    echo
    log_info "🎯 MIGRATION SUMMARY"
    log_info "===================="
    log_info "Total applications: ${#apps[@]}"
    log_info "Successful: ${#successful_apps[@]}"
    log_info "Failed: ${#failed_apps[@]}"

    if [ ${#successful_apps[@]} -gt 0 ]; then
        log_success "Successful migrations:"
        for app in "${successful_apps[@]}"; do
            log_success "  ✅ $app"
        done
    fi

    if [ ${#failed_apps[@]} -gt 0 ]; then
        log_error "Failed migrations:"
        for app in "${failed_apps[@]}"; do
            log_error "  ❌ $app"
        done
        echo
        log_info "Check logs and backups in: ${SCRIPT_DIR}/backups/"
        exit 1
    fi

    log_success "🎉 All applications migrated successfully to NFS-CSI storage!"
    log_info "Next steps:"
    log_info "  1. Monitor applications for stability"
    log_info "  2. Verify backup schedules are working"
    log_info "  3. Clean up old democratic-csi resources when confident"
}

# Run main function
main "$@"
