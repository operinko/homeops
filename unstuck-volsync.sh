#!/bin/bash

# Script to clean up stuck VolSync resources
# This script will:
# 1. Remove finalizers from stuck PVCs
# 2. Remove finalizers from stuck VolumeSnapshots
# 3. Delete stuck PVCs
# 4. Delete stuck VolumeSnapshots
# 5. Recreate the resources

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if namespace is provided
if [ -z "$1" ]; then
  echo -e "${RED}Error: Namespace is required${NC}"
  echo "Usage: $0 <namespace> [app_name]"
  exit 1
fi

NAMESPACE=$1
APP_NAME=$2

echo -e "${BLUE}Starting cleanup for namespace: ${NAMESPACE}${NC}"
if [ ! -z "$APP_NAME" ]; then
  echo -e "${BLUE}Filtering for app: ${APP_NAME}${NC}"
fi

# Function to remove finalizers from a resource
remove_finalizers() {
  local resource_type=$1
  local resource_name=$2
  
  echo -e "${YELLOW}Removing finalizers from ${resource_type}/${resource_name}...${NC}"
  
  # Get the resource in JSON format
  kubectl get ${resource_type} ${resource_name} -n ${NAMESPACE} -o json > /tmp/resource.json
  
  # Remove finalizers
  cat /tmp/resource.json | jq '.metadata.finalizers = []' > /tmp/resource_no_finalizers.json
  
  # Apply the change
  kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/${resource_type}s/${resource_name}" -f /tmp/resource_no_finalizers.json
  
  echo -e "${GREEN}Finalizers removed from ${resource_type}/${resource_name}${NC}"
}

# Function to remove finalizers from a VolumeSnapshot
remove_snapshot_finalizers() {
  local snapshot_name=$1
  
  echo -e "${YELLOW}Removing finalizers from VolumeSnapshot/${snapshot_name}...${NC}"
  
  # Get the snapshot in JSON format
  kubectl get volumesnapshot ${snapshot_name} -n ${NAMESPACE} -o json > /tmp/snapshot.json
  
  # Remove finalizers
  cat /tmp/snapshot.json | jq '.metadata.finalizers = []' > /tmp/snapshot_no_finalizers.json
  
  # Apply the change
  kubectl replace --raw "/apis/snapshot.storage.k8s.io/v1/namespaces/${NAMESPACE}/volumesnapshots/${snapshot_name}" -f /tmp/snapshot_no_finalizers.json
  
  echo -e "${GREEN}Finalizers removed from VolumeSnapshot/${snapshot_name}${NC}"
}

# Get stuck PVCs
if [ -z "$APP_NAME" ]; then
  STUCK_PVCS=$(kubectl get pvc -n ${NAMESPACE} --field-selector=status.phase=Pending -o jsonpath='{.items[*].metadata.name}')
else
  STUCK_PVCS=$(kubectl get pvc -n ${NAMESPACE} --field-selector=status.phase=Pending -l "app.kubernetes.io/name=${APP_NAME}" -o jsonpath='{.items[*].metadata.name}')
fi

# Process stuck PVCs
if [ ! -z "$STUCK_PVCS" ]; then
  echo -e "${YELLOW}Found stuck PVCs: ${STUCK_PVCS}${NC}"
  
  for PVC in $STUCK_PVCS; do
    echo -e "${BLUE}Processing PVC: ${PVC}${NC}"
    
    # Get the PVC's finalizers
    FINALIZERS=$(kubectl get pvc ${PVC} -n ${NAMESPACE} -o jsonpath='{.metadata.finalizers}')
    
    if [ ! -z "$FINALIZERS" ]; then
      # Remove finalizers
      remove_finalizers "persistentvolumeclaim" ${PVC}
    fi
    
    # Delete the PVC
    echo -e "${YELLOW}Deleting PVC: ${PVC}${NC}"
    kubectl delete pvc ${PVC} -n ${NAMESPACE} --force --grace-period=0
    echo -e "${GREEN}PVC ${PVC} deleted${NC}"
  done
else
  echo -e "${GREEN}No stuck PVCs found${NC}"
fi

# Get stuck VolumeSnapshots
if [ -z "$APP_NAME" ]; then
  STUCK_SNAPSHOTS=$(kubectl get volumesnapshot -n ${NAMESPACE} --field-selector=status.readyToUse=false -o jsonpath='{.items[*].metadata.name}')
else
  STUCK_SNAPSHOTS=$(kubectl get volumesnapshot -n ${NAMESPACE} --field-selector=status.readyToUse=false -l "app.kubernetes.io/name=${APP_NAME}" -o jsonpath='{.items[*].metadata.name}')
fi

# Process stuck VolumeSnapshots
if [ ! -z "$STUCK_SNAPSHOTS" ]; then
  echo -e "${YELLOW}Found stuck VolumeSnapshots: ${STUCK_SNAPSHOTS}${NC}"
  
  for SNAPSHOT in $STUCK_SNAPSHOTS; do
    echo -e "${BLUE}Processing VolumeSnapshot: ${SNAPSHOT}${NC}"
    
    # Get the snapshot's finalizers
    FINALIZERS=$(kubectl get volumesnapshot ${SNAPSHOT} -n ${NAMESPACE} -o jsonpath='{.metadata.finalizers}')
    
    if [ ! -z "$FINALIZERS" ]; then
      # Remove finalizers
      remove_snapshot_finalizers ${SNAPSHOT}
    fi
    
    # Delete the snapshot
    echo -e "${YELLOW}Deleting VolumeSnapshot: ${SNAPSHOT}${NC}"
    kubectl delete volumesnapshot ${SNAPSHOT} -n ${NAMESPACE} --force --grace-period=0
    echo -e "${GREEN}VolumeSnapshot ${SNAPSHOT} deleted${NC}"
  done
else
  echo -e "${GREEN}No stuck VolumeSnapshots found${NC}"
fi

# Get ReplicationSources with errors
if [ -z "$APP_NAME" ]; then
  STUCK_SOURCES=$(kubectl get replicationsource -n ${NAMESPACE} -o jsonpath='{range .items[?(@.status.conditions[0].status=="False")]}{.metadata.name}{" "}{end}')
else
  STUCK_SOURCES=$(kubectl get replicationsource -n ${NAMESPACE} -l "app.kubernetes.io/name=${APP_NAME}" -o jsonpath='{range .items[?(@.status.conditions[0].status=="False")]}{.metadata.name}{" "}{end}')
fi

# Process stuck ReplicationSources
if [ ! -z "$STUCK_SOURCES" ]; then
  echo -e "${YELLOW}Found stuck ReplicationSources: ${STUCK_SOURCES}${NC}"
  
  for SOURCE in $STUCK_SOURCES; do
    echo -e "${BLUE}Processing ReplicationSource: ${SOURCE}${NC}"
    
    # Trigger a manual sync
    echo -e "${YELLOW}Triggering manual sync for ReplicationSource: ${SOURCE}${NC}"
    TIMESTAMP=$(date +%s)
    kubectl patch replicationsource ${SOURCE} -n ${NAMESPACE} --type=merge -p "{\"spec\":{\"trigger\":{\"manual\":\"${TIMESTAMP}\"}}}"
    echo -e "${GREEN}Manual sync triggered for ReplicationSource ${SOURCE}${NC}"
  done
else
  echo -e "${GREEN}No stuck ReplicationSources found${NC}"
fi

echo -e "${GREEN}Cleanup completed for namespace: ${NAMESPACE}${NC}"
