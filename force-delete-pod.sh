#!/bin/bash

# Simple script to force delete a stuck pod using the Kubernetes API directly
# Usage: ./force-delete-pod.sh <namespace> <pod-name>

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if namespace and pod name are provided
if [ -z "$1" ] || [ -z "$2" ]; then
  echo -e "${RED}Error: Namespace and pod name are required${NC}"
  echo "Usage: $0 <namespace> <pod-name>"
  exit 1
fi

NAMESPACE=$1
POD_NAME=$2

echo -e "${BLUE}Starting force deletion of pod ${POD_NAME} in namespace ${NAMESPACE}...${NC}"

# Check if the pod exists
if ! kubectl get pod ${POD_NAME} -n ${NAMESPACE} &>/dev/null; then
  echo -e "${YELLOW}Pod ${POD_NAME} does not exist in namespace ${NAMESPACE}. Nothing to do.${NC}"
  exit 0
fi

# Start kubectl proxy
echo -e "${YELLOW}Starting kubectl proxy...${NC}"
kubectl proxy &
PROXY_PID=$!
sleep 2

# Get the pod JSON
echo -e "${YELLOW}Getting pod JSON...${NC}"
curl -s localhost:8001/api/v1/namespaces/${NAMESPACE}/pods/${POD_NAME} > /tmp/pod.json

# Remove finalizers
echo -e "${YELLOW}Removing finalizers from JSON...${NC}"
cat /tmp/pod.json | jq '.metadata.finalizers = []' > /tmp/pod_no_finalizers.json

# Update the pod
echo -e "${YELLOW}Updating pod without finalizers...${NC}"
curl -s -X PUT localhost:8001/api/v1/namespaces/${NAMESPACE}/pods/${POD_NAME} -H "Content-Type: application/json" -d @/tmp/pod_no_finalizers.json > /dev/null

# Delete the pod
echo -e "${YELLOW}Force deleting pod...${NC}"
curl -s -X DELETE localhost:8001/api/v1/namespaces/${NAMESPACE}/pods/${POD_NAME}?gracePeriodSeconds=0 > /dev/null

# Kill the proxy
echo -e "${YELLOW}Stopping kubectl proxy...${NC}"
kill $PROXY_PID

# Verify pod is gone
sleep 2
if ! kubectl get pod ${POD_NAME} -n ${NAMESPACE} &>/dev/null; then
  echo -e "${GREEN}Pod ${POD_NAME} successfully deleted${NC}"
else
  echo -e "${RED}Warning: Pod ${POD_NAME} still exists. You may need to restart the node or contact cluster administrator.${NC}"
  
  # Try one more time with kubectl
  echo -e "${YELLOW}Trying one more time with kubectl force delete...${NC}"
  kubectl delete pod ${POD_NAME} -n ${NAMESPACE} --force --grace-period=0
  
  sleep 2
  if ! kubectl get pod ${POD_NAME} -n ${NAMESPACE} &>/dev/null; then
    echo -e "${GREEN}Pod ${POD_NAME} successfully deleted${NC}"
  else
    echo -e "${RED}Warning: Pod ${POD_NAME} still exists. You may need to restart the node or contact cluster administrator.${NC}"
  fi
fi

echo -e "${GREEN}Force deletion process completed${NC}"
