#!/bin/bash

# Validation Script: Verify NFS-CSI Migration Success
# Companion script to migrate-to-nfs-csi.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} ${1}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} ${1}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} ${1}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} ${1}"
}

# Check application health
check_application_health() {
    local namespace="$1"
    local app="$2"
    
    log_info "Checking health of $namespace/$app..."
    
    # Check if PVC exists and is bound
    local pvc_status=$(kubectl get pvc "$app" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    local storage_class=$(kubectl get pvc "$app" -n "$namespace" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "Unknown")
    
    if [ "$pvc_status" != "Bound" ]; then
        log_error "PVC $app in $namespace is not bound (status: $pvc_status)"
        return 1
    fi
    
    if [ "$storage_class" != "nfs-csi" ]; then
        log_error "PVC $app in $namespace is not using nfs-csi storage class (using: $storage_class)"
        return 1
    fi
    
    log_success "PVC: Bound with nfs-csi storage class"
    
    # Check if pod is running
    local pod=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$pod" ]; then
        log_warning "No pod found for $namespace/$app"
        return 1
    fi
    
    local pod_status=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    local ready=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    
    if [ "$pod_status" != "Running" ] || [ "$ready" != "True" ]; then
        log_error "Pod $pod is not running/ready (status: $pod_status, ready: $ready)"
        return 1
    fi
    
    log_success "Pod: Running and ready"
    
    # Check VolSync ReplicationSource
    if kubectl get replicationsource "$app" -n "$namespace" &> /dev/null; then
        local volsync_storage=$(kubectl get replicationsource "$app" -n "$namespace" -o jsonpath='{.spec.restic.storageClassName}' 2>/dev/null || echo "Unknown")
        local volsync_cache_storage=$(kubectl get replicationsource "$app" -n "$namespace" -o jsonpath='{.spec.restic.cacheStorageClassName}' 2>/dev/null || echo "Unknown")
        
        if [ "$volsync_storage" = "nfs-csi" ] && [ "$volsync_cache_storage" = "nfs-csi" ]; then
            log_success "VolSync: Using nfs-csi storage classes"
        else
            log_error "VolSync: Not using nfs-csi storage classes (storage: $volsync_storage, cache: $volsync_cache_storage)"
            return 1
        fi
    else
        log_warning "No VolSync ReplicationSource found"
    fi
    
    # Try health check endpoint if available
    if kubectl exec -n "$namespace" "$pod" -- wget -q -O - http://localhost:80/ping &> /dev/null; then
        log_success "Health endpoint: Responding"
    elif kubectl exec -n "$namespace" "$pod" -- curl -s http://localhost:80/health &> /dev/null; then
        log_success "Health endpoint: Responding"
    else
        log_info "Health endpoint: Not available or not responding"
    fi
    
    return 0
}

# Check all migrated applications
check_all_applications() {
    log_info "Validating all migrated applications..."
    
    # Define applications that should be migrated
    declare -A target_apps=(
        ["media"]="tautulli sonarr radarr sabnzbd prowlarr bazarr recyclarr huntarr spotarr wizarr"
        ["default"]="atuin"
        ["security"]="vaultwarden"
        ["database"]="dragonfly"
        ["network"]="technitium"
        ["tools"]="headlamp"
        ["observability"]="gatus loki prometheus-kube-prometheus-stack"
    )
    
    local total_apps=0
    local healthy_apps=0
    local failed_apps=()
    
    for namespace in "${!target_apps[@]}"; do
        for app in ${target_apps[$namespace]}; do
            # Check if PVC exists
            if kubectl get pvc "$app" -n "$namespace" &> /dev/null; then
                total_apps=$((total_apps + 1))
                echo "----------------------------------------"
                
                if check_application_health "$namespace" "$app"; then
                    log_success "✅ $namespace/$app is healthy"
                    healthy_apps=$((healthy_apps + 1))
                else
                    log_error "❌ $namespace/$app has issues"
                    failed_apps+=("$namespace/$app")
                fi
            fi
        done
    done
    
    echo "========================================"
    log_info "VALIDATION SUMMARY"
    log_info "Total applications checked: $total_apps"
    log_info "Healthy applications: $healthy_apps"
    log_info "Failed applications: $((total_apps - healthy_apps))"
    
    if [ ${#failed_apps[@]} -gt 0 ]; then
        log_error "Applications with issues:"
        for app in "${failed_apps[@]}"; do
            log_error "  ❌ $app"
        done
        return 1
    fi
    
    log_success "🎉 All applications are healthy!"
    return 0
}

# Check storage class usage
check_storage_usage() {
    log_info "Checking storage class usage across cluster..."
    
    echo "Democratic-CSI PVCs still in use:"
    kubectl get pvc --all-namespaces -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,STORAGE_CLASS:.spec.storageClassName,STATUS:.status.phase" | grep -E "democratic" || echo "None found"
    
    echo
    echo "NFS-CSI PVCs:"
    kubectl get pvc --all-namespaces -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,STORAGE_CLASS:.spec.storageClassName,STATUS:.status.phase" | grep -E "nfs-csi" | wc -l | xargs echo "Total NFS-CSI PVCs:"
}

# Check VolSync backup status
check_volsync_status() {
    log_info "Checking VolSync backup status..."
    
    local namespaces=("media" "default" "security" "database" "network" "tools" "observability")
    
    for namespace in "${namespaces[@]}"; do
        local sources=$(kubectl get replicationsource -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        if [ -n "$sources" ]; then
            echo "Namespace: $namespace"
            for source in $sources; do
                local last_sync=$(kubectl get replicationsource "$source" -n "$namespace" -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo "Never")
                local result=$(kubectl get replicationsource "$source" -n "$namespace" -o jsonpath='{.status.latestMoverStatus.result}' 2>/dev/null || echo "Unknown")
                local next_sync=$(kubectl get replicationsource "$source" -n "$namespace" -o jsonpath='{.status.nextSyncTime}' 2>/dev/null || echo "Unknown")
                
                echo "  $source: Last=$last_sync, Result=$result, Next=$next_sync"
            done
            echo
        fi
    done
}

# Generate migration report
generate_report() {
    local report_file="migration-validation-$(date +%Y%m%d-%H%M%S).txt"
    
    log_info "Generating validation report: $report_file"
    
    {
        echo "NFS-CSI Migration Validation Report"
        echo "Generated: $(date)"
        echo "========================================"
        echo
        
        echo "STORAGE CLASS USAGE:"
        echo "-------------------"
        check_storage_usage
        echo
        
        echo "VOLSYNC STATUS:"
        echo "---------------"
        check_volsync_status
        echo
        
        echo "APPLICATION HEALTH:"
        echo "-------------------"
        check_all_applications
        
    } > "$report_file"
    
    log_success "Report saved to: $report_file"
}

# Main function
main() {
    log_info "Starting NFS-CSI migration validation"
    
    case "${1:-check}" in
        "check"|"health")
            check_all_applications
            ;;
        "storage")
            check_storage_usage
            ;;
        "volsync")
            check_volsync_status
            ;;
        "report")
            generate_report
            ;;
        "all")
            check_all_applications
            echo
            check_storage_usage
            echo
            check_volsync_status
            ;;
        *)
            echo "Usage: $0 [check|storage|volsync|report|all]"
            echo "  check   - Check application health (default)"
            echo "  storage - Check storage class usage"
            echo "  volsync - Check VolSync backup status"
            echo "  report  - Generate full validation report"
            echo "  all     - Run all checks"
            exit 1
            ;;
    esac
}

main "$@"
