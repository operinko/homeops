#!/bin/bash

# Script to clean up stuck VolSync PVCs
# Usage: ./volsync-cleanup.sh [namespace]

set -e

NAMESPACE=${1:-"all"}

echo "Looking for stuck VolSync PVCs..."

if [ "$NAMESPACE" = "all" ]; then
  NAMESPACES=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')
else
  NAMESPACES=$NAMESPACE
fi

for ns in $NAMESPACES; do
  echo "Checking namespace: $ns"

  # Find PVCs with volsync.backube/cleanup label that are stuck in terminating state
  PVCS=$(kubectl get pvc -n $ns -l volsync.backube/cleanup -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

  if [ -z "$PVCS" ]; then
    echo "No stuck VolSync PVCs found in namespace $ns"
    continue
  fi

  for pvc in $PVCS; do
    echo "Found stuck PVC: $pvc in namespace $ns"

    # Find pods using this PVC
    PODS=$(kubectl get pods -n $ns -o jsonpath='{range .items[*]}{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\t"}{@.metadata.name}{"\n"}{end}{end}' | grep "^$pvc" | awk '{print $2}' || echo "")

    if [ -n "$PODS" ]; then
      for pod in $PODS; do
        echo "Deleting pod $pod in namespace $ns that is using PVC $pvc"
        kubectl delete pod -n $ns $pod --force --grace-period=0
      done
    else
      echo "No pods found using PVC $pvc in namespace $ns"
    fi

    # Remove the finalizer from the PVC
    echo "Removing finalizer from PVC $pvc in namespace $ns"
    kubectl patch pvc $pvc -n $ns --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

    echo "PVC $pvc in namespace $ns should now be deleted"
  done
done

echo "Cleanup completed"
