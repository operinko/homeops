#!/bin/bash

# Script to fix StorageClass issues
# This script will:
# 1. Suspend the democratic-csi-nfs Kustomization
# 2. Delete the democratic-volsync-nfs StorageClass
# 3. Resume the democratic-csi-nfs Kustomization
# 4. Trigger reconciliation of the Kustomization

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Starting StorageClass fix process...${NC}"

# Step 1: Suspend the democratic-csi-nfs Kustomization
echo -e "${YELLOW}Suspending democratic-csi-nfs Kustomization...${NC}"
flux suspend kustomization democratic-csi-nfs -n storage
echo -e "${GREEN}Kustomization suspended${NC}"

# Step 2: Delete the democratic-volsync-nfs StorageClass
echo -e "${YELLOW}Deleting democratic-volsync-nfs StorageClass...${NC}"
kubectl delete storageclass democratic-volsync-nfs --ignore-not-found
echo -e "${GREEN}StorageClass deleted${NC}"

# Step 3: Resume the democratic-csi-nfs Kustomization
echo -e "${YELLOW}Resuming democratic-csi-nfs Kustomization...${NC}"
flux resume kustomization democratic-csi-nfs -n storage
echo -e "${GREEN}Kustomization resumed${NC}"

# Step 4: Trigger reconciliation of the Kustomization
echo -e "${YELLOW}Triggering reconciliation of democratic-csi-nfs Kustomization...${NC}"
flux reconcile kustomization democratic-csi-nfs -n storage --with-source
echo -e "${GREEN}Reconciliation triggered${NC}"

echo -e "${GREEN}StorageClass fix process completed${NC}"
echo -e "${YELLOW}Note: It may take some time for the Kustomization to be fully reconciled${NC}"
