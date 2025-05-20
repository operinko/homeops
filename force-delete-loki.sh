#!/bin/bash

# Script to force delete the stuck Loki pod and clean up associated resources
# This script will:
# 1. Remove finalizers from the stuck pod
# 2. Force delete the pod
# 3. Remove finalizers from the PVC
# 4. Delete the PVC
# 5. Suspend the Loki HelmRelease
# 6. Delete the old StatefulSet
# 7. Resume the Loki HelmRelease

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NAMESPACE="observability"
POD_NAME="loki-0"
PVC_NAME="storage-loki-0"
STATEFULSET_NAME="loki"
HELMRELEASE_NAME="loki"

echo -e "${BLUE}Starting cleanup process for stuck Loki pod...${NC}"

# Step 1: Check if the pod exists
echo -e "${YELLOW}Checking if pod ${POD_NAME} exists...${NC}"
if kubectl get pod ${POD_NAME} -n ${NAMESPACE} &>/dev/null; then
  echo -e "${GREEN}Pod ${POD_NAME} exists. Proceeding with cleanup.${NC}"

  # Step 2: Remove finalizers from the pod
  echo -e "${YELLOW}Removing finalizers from pod ${POD_NAME}...${NC}"

  # Try to patch the pod directly instead of using the finalize endpoint
  if kubectl patch pod ${POD_NAME} -n ${NAMESPACE} -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null; then
    echo -e "${GREEN}Finalizers removed from pod ${POD_NAME} using patch method${NC}"
  else
    echo -e "${YELLOW}Failed to patch pod. Trying alternative method...${NC}"

    # Alternative method: use kubectl proxy to access the API server directly
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
    curl -s -X PUT localhost:8001/api/v1/namespaces/${NAMESPACE}/pods/${POD_NAME} -H "Content-Type: application/json" -d @/tmp/pod_no_finalizers.json

    # Kill the proxy
    echo -e "${YELLOW}Stopping kubectl proxy...${NC}"
    kill $PROXY_PID

    echo -e "${GREEN}Attempted to remove finalizers from pod ${POD_NAME} using proxy method${NC}"
  fi

  # Step 3: Force delete the pod
  echo -e "${YELLOW}Force deleting pod ${POD_NAME}...${NC}"

  # Try kubectl delete first
  if kubectl delete pod ${POD_NAME} -n ${NAMESPACE} --force --grace-period=0 2>/dev/null; then
    echo -e "${GREEN}Pod ${POD_NAME} deleted using kubectl delete${NC}"
  else
    echo -e "${YELLOW}Failed to delete pod using kubectl. Trying alternative method...${NC}"

    # Alternative method: use kubectl proxy to access the API server directly
    echo -e "${YELLOW}Starting kubectl proxy...${NC}"
    kubectl proxy &
    PROXY_PID=$!
    sleep 2

    # Delete the pod using the API directly
    echo -e "${YELLOW}Deleting pod using API directly...${NC}"
    curl -s -X DELETE localhost:8001/api/v1/namespaces/${NAMESPACE}/pods/${POD_NAME}?gracePeriodSeconds=0 > /dev/null

    # Kill the proxy
    echo -e "${YELLOW}Stopping kubectl proxy...${NC}"
    kill $PROXY_PID

    echo -e "${GREEN}Attempted to delete pod ${POD_NAME} using API directly${NC}"
  fi

  # Verify pod is gone
  if ! kubectl get pod ${POD_NAME} -n ${NAMESPACE} &>/dev/null; then
    echo -e "${GREEN}Pod ${POD_NAME} successfully deleted${NC}"
  else
    echo -e "${RED}Warning: Pod ${POD_NAME} still exists. You may need to restart the node or contact cluster administrator.${NC}"
  fi
else
  echo -e "${YELLOW}Pod ${POD_NAME} does not exist. Skipping pod cleanup.${NC}"
fi

# Step 4: Check if the PVC exists
echo -e "${YELLOW}Checking if PVC ${PVC_NAME} exists...${NC}"
if kubectl get pvc ${PVC_NAME} -n ${NAMESPACE} &>/dev/null; then
  echo -e "${GREEN}PVC ${PVC_NAME} exists. Proceeding with cleanup.${NC}"

  # Step 5: Remove finalizers from the PVC
  echo -e "${YELLOW}Removing finalizers from PVC ${PVC_NAME}...${NC}"

  # Try to patch the PVC directly
  if kubectl patch pvc ${PVC_NAME} -n ${NAMESPACE} -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null; then
    echo -e "${GREEN}Finalizers removed from PVC ${PVC_NAME} using patch method${NC}"
  else
    echo -e "${YELLOW}Failed to patch PVC. Trying alternative method...${NC}"

    # Alternative method: use kubectl proxy to access the API server directly
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
    curl -s -X PUT localhost:8001/api/v1/namespaces/${NAMESPACE}/persistentvolumeclaims/${PVC_NAME} -H "Content-Type: application/json" -d @/tmp/pvc_no_finalizers.json

    # Kill the proxy
    echo -e "${YELLOW}Stopping kubectl proxy...${NC}"
    kill $PROXY_PID

    echo -e "${GREEN}Attempted to remove finalizers from PVC ${PVC_NAME} using proxy method${NC}"
  fi

  # Step 6: Delete the PVC
  echo -e "${YELLOW}Deleting PVC ${PVC_NAME}...${NC}"

  # Try kubectl delete first
  if kubectl delete pvc ${PVC_NAME} -n ${NAMESPACE} --force --grace-period=0 2>/dev/null; then
    echo -e "${GREEN}PVC ${PVC_NAME} deleted using kubectl delete${NC}"
  else
    echo -e "${YELLOW}Failed to delete PVC using kubectl. Trying alternative method...${NC}"

    # Alternative method: use kubectl proxy to access the API server directly
    echo -e "${YELLOW}Starting kubectl proxy...${NC}"
    kubectl proxy &
    PROXY_PID=$!
    sleep 2

    # Delete the PVC using the API directly
    echo -e "${YELLOW}Deleting PVC using API directly...${NC}"
    curl -s -X DELETE localhost:8001/api/v1/namespaces/${NAMESPACE}/persistentvolumeclaims/${PVC_NAME}?gracePeriodSeconds=0 > /dev/null

    # Kill the proxy
    echo -e "${YELLOW}Stopping kubectl proxy...${NC}"
    kill $PROXY_PID

    echo -e "${GREEN}Attempted to delete PVC ${PVC_NAME} using API directly${NC}"
  fi

  # Verify PVC is gone
  if ! kubectl get pvc ${PVC_NAME} -n ${NAMESPACE} &>/dev/null; then
    echo -e "${GREEN}PVC ${PVC_NAME} successfully deleted${NC}"
  else
    echo -e "${RED}Warning: PVC ${PVC_NAME} still exists. You may need to manually delete it.${NC}"
  fi
else
  echo -e "${YELLOW}PVC ${PVC_NAME} does not exist. Skipping PVC cleanup.${NC}"
fi

# Step 7: Suspend the Loki HelmRelease
echo -e "${YELLOW}Suspending HelmRelease ${HELMRELEASE_NAME}...${NC}"
flux suspend helmrelease ${HELMRELEASE_NAME} -n ${NAMESPACE}
echo -e "${GREEN}HelmRelease ${HELMRELEASE_NAME} suspended${NC}"

# Step 8: Check if the old StatefulSet exists
echo -e "${YELLOW}Checking if StatefulSet ${STATEFULSET_NAME} exists...${NC}"
if kubectl get statefulset ${STATEFULSET_NAME} -n ${NAMESPACE} &>/dev/null; then
  # Get the UID of the StatefulSet
  STATEFULSET_UID=$(kubectl get statefulset ${STATEFULSET_NAME} -n ${NAMESPACE} -o jsonpath='{.metadata.uid}')

  if [ "${STATEFULSET_UID}" == "98eec06e-9de7-4102-9c04-443cc60c6972" ]; then
    echo -e "${GREEN}Found old StatefulSet ${STATEFULSET_NAME}. Proceeding with cleanup.${NC}"

    # Step 9: Remove finalizers from the StatefulSet
    echo -e "${YELLOW}Removing finalizers from StatefulSet ${STATEFULSET_NAME}...${NC}"

    # Try to patch the StatefulSet directly
    if kubectl patch statefulset ${STATEFULSET_NAME} -n ${NAMESPACE} -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null; then
      echo -e "${GREEN}Finalizers removed from StatefulSet ${STATEFULSET_NAME} using patch method${NC}"
    else
      echo -e "${YELLOW}Failed to patch StatefulSet. Trying alternative method...${NC}"

      # Alternative method: use kubectl proxy to access the API server directly
      echo -e "${YELLOW}Starting kubectl proxy...${NC}"
      kubectl proxy &
      PROXY_PID=$!
      sleep 2

      # Get the StatefulSet JSON
      echo -e "${YELLOW}Getting StatefulSet JSON...${NC}"
      curl -s localhost:8001/apis/apps/v1/namespaces/${NAMESPACE}/statefulsets/${STATEFULSET_NAME} > /tmp/statefulset.json

      # Remove finalizers
      echo -e "${YELLOW}Removing finalizers from JSON...${NC}"
      cat /tmp/statefulset.json | jq '.metadata.finalizers = []' > /tmp/statefulset_no_finalizers.json

      # Update the StatefulSet
      echo -e "${YELLOW}Updating StatefulSet without finalizers...${NC}"
      curl -s -X PUT localhost:8001/apis/apps/v1/namespaces/${NAMESPACE}/statefulsets/${STATEFULSET_NAME} -H "Content-Type: application/json" -d @/tmp/statefulset_no_finalizers.json

      # Kill the proxy
      echo -e "${YELLOW}Stopping kubectl proxy...${NC}"
      kill $PROXY_PID

      echo -e "${GREEN}Attempted to remove finalizers from StatefulSet ${STATEFULSET_NAME} using proxy method${NC}"
    fi

    # Step 10: Delete the StatefulSet
    echo -e "${YELLOW}Deleting StatefulSet ${STATEFULSET_NAME}...${NC}"

    # Try kubectl delete first
    if kubectl delete statefulset ${STATEFULSET_NAME} -n ${NAMESPACE} --force --grace-period=0 2>/dev/null; then
      echo -e "${GREEN}StatefulSet ${STATEFULSET_NAME} deleted using kubectl delete${NC}"
    else
      echo -e "${YELLOW}Failed to delete StatefulSet using kubectl. Trying alternative method...${NC}"

      # Alternative method: use kubectl proxy to access the API server directly
      echo -e "${YELLOW}Starting kubectl proxy...${NC}"
      kubectl proxy &
      PROXY_PID=$!
      sleep 2

      # Delete the StatefulSet using the API directly
      echo -e "${YELLOW}Deleting StatefulSet using API directly...${NC}"
      curl -s -X DELETE localhost:8001/apis/apps/v1/namespaces/${NAMESPACE}/statefulsets/${STATEFULSET_NAME}?gracePeriodSeconds=0 > /dev/null

      # Kill the proxy
      echo -e "${YELLOW}Stopping kubectl proxy...${NC}"
      kill $PROXY_PID

      echo -e "${GREEN}Attempted to delete StatefulSet ${STATEFULSET_NAME} using API directly${NC}"
    fi

    # Verify StatefulSet is gone
    if ! kubectl get statefulset ${STATEFULSET_NAME} -n ${NAMESPACE} &>/dev/null; then
      echo -e "${GREEN}StatefulSet ${STATEFULSET_NAME} successfully deleted${NC}"
    else
      echo -e "${RED}Warning: StatefulSet ${STATEFULSET_NAME} still exists. You may need to manually delete it.${NC}"
    fi
  else
    echo -e "${YELLOW}Found StatefulSet ${STATEFULSET_NAME} but it's not the old one. Skipping StatefulSet cleanup.${NC}"
  fi
else
  echo -e "${YELLOW}StatefulSet ${STATEFULSET_NAME} does not exist. Skipping StatefulSet cleanup.${NC}"
fi

# Step 11: Resume the Loki HelmRelease
echo -e "${YELLOW}Waiting for resources to be fully cleaned up...${NC}"
sleep 30
echo -e "${YELLOW}Resuming HelmRelease ${HELMRELEASE_NAME}...${NC}"
flux resume helmrelease ${HELMRELEASE_NAME} -n ${NAMESPACE}
echo -e "${GREEN}HelmRelease ${HELMRELEASE_NAME} resumed${NC}"

# Step 12: Reconcile the Loki HelmRelease
echo -e "${YELLOW}Reconciling HelmRelease ${HELMRELEASE_NAME}...${NC}"
flux reconcile helmrelease ${HELMRELEASE_NAME} -n ${NAMESPACE} --with-source
echo -e "${GREEN}HelmRelease ${HELMRELEASE_NAME} reconciliation triggered${NC}"

echo -e "${GREEN}Cleanup process completed${NC}"
echo -e "${YELLOW}Note: It may take some time for all resources to be fully reconciled${NC}"
