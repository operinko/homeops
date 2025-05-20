#!/bin/bash

# Simple script to force delete a stuck PVC using the Kubernetes API directly
# Usage: ./force-delete-pvc.sh <namespace> <pvc-name>

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if namespace and PVC name are provided
if [ -z "$1" ] || [ -z "$2" ]; then
  echo -e "${RED}Error: Namespace and PVC name are required${NC}"
  echo "Usage: $0 <namespace> <pvc-name>"
  exit 1
fi

NAMESPACE=$1
PVC_NAME=$2

echo -e "${BLUE}Starting force deletion of PVC ${PVC_NAME} in namespace ${NAMESPACE}...${NC}"

# Check if the PVC exists
if ! kubectl get pvc ${PVC_NAME} -n ${NAMESPACE} &>/dev/null; then
  echo -e "${YELLOW}PVC ${PVC_NAME} does not exist in namespace ${NAMESPACE}. Nothing to do.${NC}"
  exit 0
fi

# Start kubectl proxy
echo -e "${YELLOW}Starting kubectl proxy...${NC}"
kubectl proxy &
PROXY_PID=$!
sleep 2

# Get the PVC JSON
echo -e "${YELLOW}Getting PVC JSON...${NC}"
curl -s localhost:8001/api/v1/namespaces/${NAMESPACE}/persistentvolumeclaims/${PVC_NAME} > /tmp/pvc.json

# Remove finalizers
echo -e "${YELLOW}Removing finalizers from JSON...${NC}"
cat /tmp/pvc.json | jq '.metadata.finalizers = []' > /tmp/pvc_no_finalizers.json

# Update the PVC
echo -e "${YELLOW}Updating PVC without finalizers...${NC}"
curl -s -X PUT localhost:8001/api/v1/namespaces/${NAMESPACE}/persistentvolumeclaims/${PVC_NAME} -H "Content-Type: application/json" -d @/tmp/pvc_no_finalizers.json > /dev/null

# Delete the PVC
echo -e "${YELLOW}Force deleting PVC...${NC}"
curl -s -X DELETE localhost:8001/api/v1/namespaces/${NAMESPACE}/persistentvolumeclaims/${PVC_NAME}?gracePeriodSeconds=0 > /dev/null

# Kill the proxy
echo -e "${YELLOW}Stopping kubectl proxy...${NC}"
kill $PROXY_PID

# Verify PVC is gone
sleep 2
if ! kubectl get pvc ${PVC_NAME} -n ${NAMESPACE} &>/dev/null; then
  echo -e "${GREEN}PVC ${PVC_NAME} successfully deleted${NC}"
else
  echo -e "${RED}Warning: PVC ${PVC_NAME} still exists. You may need to manually delete it.${NC}"
  
  # Try one more time with kubectl
  echo -e "${YELLOW}Trying one more time with kubectl force delete...${NC}"
  kubectl delete pvc ${PVC_NAME} -n ${NAMESPACE} --force --grace-period=0
  
  sleep 2
  if ! kubectl get pvc ${PVC_NAME} -n ${NAMESPACE} &>/dev/null; then
    echo -e "${GREEN}PVC ${PVC_NAME} successfully deleted${NC}"
  else
    echo -e "${RED}Warning: PVC ${PVC_NAME} still exists. You may need to manually delete it.${NC}"
  fi
fi

echo -e "${GREEN}Force deletion process completed${NC}"
