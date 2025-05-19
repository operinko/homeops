#!/bin/bash

# Script to fix VolumeSnapshotClass issues
# This script will:
# 1. Check if the correct VolumeSnapshotClass exists
# 2. Create it if it doesn't exist
# 3. Update any snapshots using the old class to use the new one

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Checking VolumeSnapshotClass configuration...${NC}"

# Check if the correct VolumeSnapshotClass exists
VSC_EXISTS=$(kubectl get volumesnapshotclass csi-democratic-snapshotclass-nfs -o name 2>/dev/null || echo "")

if [ -z "$VSC_EXISTS" ]; then
  echo -e "${YELLOW}VolumeSnapshotClass csi-democratic-snapshotclass-nfs does not exist. Creating it...${NC}"
  
  # Create the VolumeSnapshotClass
  cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
  name: csi-democratic-snapshotclass-nfs
deletionPolicy: Delete
driver: org.democratic-csi.nfs
EOF
  
  echo -e "${GREEN}VolumeSnapshotClass csi-democratic-snapshotclass-nfs created${NC}"
else
  echo -e "${GREEN}VolumeSnapshotClass csi-democratic-snapshotclass-nfs already exists${NC}"
fi

# Check if the old VolumeSnapshotClass exists
OLD_VSC_EXISTS=$(kubectl get volumesnapshotclass csi-democratic-snapshotclass -o name 2>/dev/null || echo "")

if [ ! -z "$OLD_VSC_EXISTS" ]; then
  echo -e "${YELLOW}Old VolumeSnapshotClass csi-democratic-snapshotclass exists. Checking for snapshots using it...${NC}"
  
  # Get snapshots using the old class
  SNAPSHOTS=$(kubectl get volumesnapshot --all-namespaces -o jsonpath='{range .items[?(@.spec.volumeSnapshotClassName=="csi-democratic-snapshotclass")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')
  
  if [ ! -z "$SNAPSHOTS" ]; then
    echo -e "${YELLOW}Found snapshots using the old class:${NC}"
    echo "$SNAPSHOTS"
    
    # Update each snapshot to use the new class
    while read -r line; do
      if [ ! -z "$line" ]; then
        NS=$(echo $line | cut -d' ' -f1)
        NAME=$(echo $line | cut -d' ' -f2)
        
        echo -e "${YELLOW}Updating snapshot ${NS}/${NAME} to use the new class...${NC}"
        
        # Get the snapshot in JSON format
        kubectl get volumesnapshot ${NAME} -n ${NS} -o json > /tmp/snapshot.json
        
        # Update the class
        cat /tmp/snapshot.json | jq '.spec.volumeSnapshotClassName = "csi-democratic-snapshotclass-nfs"' > /tmp/snapshot_updated.json
        
        # Apply the change
        kubectl replace --raw "/apis/snapshot.storage.k8s.io/v1/namespaces/${NS}/volumesnapshots/${NAME}" -f /tmp/snapshot_updated.json
        
        echo -e "${GREEN}Updated snapshot ${NS}/${NAME}${NC}"
      fi
    done <<< "$SNAPSHOTS"
  else
    echo -e "${GREEN}No snapshots found using the old class${NC}"
  fi
  
  # Delete the old class
  echo -e "${YELLOW}Deleting old VolumeSnapshotClass csi-democratic-snapshotclass...${NC}"
  kubectl delete volumesnapshotclass csi-democratic-snapshotclass
  echo -e "${GREEN}Old VolumeSnapshotClass deleted${NC}"
else
  echo -e "${GREEN}Old VolumeSnapshotClass does not exist${NC}"
fi

echo -e "${GREEN}VolumeSnapshotClass configuration fixed${NC}"
