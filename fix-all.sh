#!/bin/bash

# Master script to fix all issues
# This script will:
# 1. Fix StorageClass issues
# 2. Fix VolumeSnapshotClass issues
# 3. Clean up stuck resources
# 4. Trigger reconciliation of Flux resources

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

echo -e "${BLUE}Starting comprehensive fix process for namespace: ${NAMESPACE}${NC}"
if [ ! -z "$APP_NAME" ]; then
  echo -e "${BLUE}Filtering for app: ${APP_NAME}${NC}"
fi

# Step 1: Fix StorageClass issues
echo -e "${BLUE}Step 1: Fixing StorageClass issues...${NC}"
./fix-storageclass.sh
echo -e "${GREEN}StorageClass issues fixed${NC}"

# Wait for the StorageClass to be recreated
echo -e "${YELLOW}Waiting for StorageClass to be recreated...${NC}"
sleep 30

# Step 2: Fix VolumeSnapshotClass issues
echo -e "${BLUE}Step 2: Fixing VolumeSnapshotClass issues...${NC}"
./fix-volumesnapshotclass.sh
echo -e "${GREEN}VolumeSnapshotClass issues fixed${NC}"

# Step 3: Clean up stuck resources
echo -e "${BLUE}Step 3: Cleaning up stuck resources...${NC}"
./unstuck-volsync.sh ${NAMESPACE} ${APP_NAME}
echo -e "${GREEN}Stuck resources cleaned up${NC}"

# Step 4: Trigger reconciliation of Flux resources
echo -e "${BLUE}Step 4: Triggering reconciliation of Flux resources...${NC}"

# Get all HelmReleases in the namespace
if [ -z "$APP_NAME" ]; then
  HELM_RELEASES=$(kubectl get helmrelease -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}')
else
  HELM_RELEASES=$(kubectl get helmrelease -n ${NAMESPACE} -l "app.kubernetes.io/name=${APP_NAME}" -o jsonpath='{.items[*].metadata.name}')
fi

# Reconcile each HelmRelease
if [ ! -z "$HELM_RELEASES" ]; then
  echo -e "${YELLOW}Found HelmReleases: ${HELM_RELEASES}${NC}"
  
  for HR in $HELM_RELEASES; do
    echo -e "${YELLOW}Reconciling HelmRelease: ${HR}${NC}"
    flux reconcile helmrelease ${HR} -n ${NAMESPACE} --with-source
    echo -e "${GREEN}HelmRelease ${HR} reconciliation triggered${NC}"
  done
else
  echo -e "${YELLOW}No HelmReleases found in namespace ${NAMESPACE}${NC}"
fi

# Get all Kustomizations in the namespace
if [ -z "$APP_NAME" ]; then
  KUSTOMIZATIONS=$(kubectl get kustomization -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}')
else
  KUSTOMIZATIONS=$(kubectl get kustomization -n ${NAMESPACE} -l "app.kubernetes.io/name=${APP_NAME}" -o jsonpath='{.items[*].metadata.name}')
fi

# Reconcile each Kustomization
if [ ! -z "$KUSTOMIZATIONS" ]; then
  echo -e "${YELLOW}Found Kustomizations: ${KUSTOMIZATIONS}${NC}"
  
  for KS in $KUSTOMIZATIONS; do
    echo -e "${YELLOW}Reconciling Kustomization: ${KS}${NC}"
    flux reconcile kustomization ${KS} -n ${NAMESPACE} --with-source
    echo -e "${GREEN}Kustomization ${KS} reconciliation triggered${NC}"
  done
else
  echo -e "${YELLOW}No Kustomizations found in namespace ${NAMESPACE}${NC}"
fi

echo -e "${GREEN}Comprehensive fix process completed for namespace: ${NAMESPACE}${NC}"
echo -e "${YELLOW}Note: It may take some time for all resources to be fully reconciled${NC}"
