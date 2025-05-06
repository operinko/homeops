#!/bin/bash

# This script helps migrate PVCs from nfs-csi to ceph-block
# It will:
# 1. Scale down the deployments
# 2. Delete the old PVCs
# 3. Apply the new PVCs with ceph-block storage class
# 4. Scale up the deployments

set -e

# Function to handle errors
handle_error() {
  echo "Error occurred at line $1"
  exit 1
}

trap 'handle_error $LINENO' ERR

# Function to scale down a deployment
scale_down() {
  local namespace=$1
  local deployment=$2
  
  echo "Scaling down $namespace/$deployment..."
  kubectl scale deployment -n $namespace $deployment --replicas=0
  
  # Wait for the pods to terminate
  echo "Waiting for pods to terminate..."
  kubectl wait --for=delete pod -l app.kubernetes.io/name=$deployment -n $namespace --timeout=60s || true
}

# Function to scale up a deployment
scale_up() {
  local namespace=$1
  local deployment=$2
  
  echo "Scaling up $namespace/$deployment..."
  kubectl scale deployment -n $namespace $deployment --replicas=1
}

# Function to delete a PVC
delete_pvc() {
  local namespace=$1
  local pvc=$2
  
  echo "Deleting PVC $namespace/$pvc..."
  kubectl delete pvc -n $namespace $pvc --wait=false
}

# Function to apply a PVC from a file
apply_pvc() {
  local file=$1
  
  echo "Applying PVCs from $file..."
  kubectl apply -f $file
}

# Migrate Radarr
migrate_radarr() {
  echo "Migrating Radarr..."
  scale_down media radarr
  delete_pvc media radarr
  delete_pvc media radarr-cache
  apply_pvc kubernetes/apps/media/radarr/app/pvc.yaml
  scale_up media radarr
}

# Migrate Sonarr
migrate_sonarr() {
  echo "Migrating Sonarr..."
  scale_down media sonarr
  delete_pvc media sonarr
  delete_pvc media sonarr-cache
  apply_pvc kubernetes/apps/media/sonarr/app/pvc.yaml
  scale_up media sonarr
}

# Migrate Prowlarr
migrate_prowlarr() {
  echo "Migrating Prowlarr..."
  scale_down media prowlarr
  delete_pvc media prowlarr
  apply_pvc kubernetes/apps/media/prowlarr/app/pvc.yaml
  scale_up media prowlarr
}

# Migrate Recyclarr
migrate_recyclarr() {
  echo "Migrating Recyclarr..."
  scale_down media recyclarr
  delete_pvc media recyclarr
  apply_pvc kubernetes/apps/media/recyclarr/app/pvc.yaml
  scale_up media recyclarr
}

# Migrate Tautulli
migrate_tautulli() {
  echo "Migrating Tautulli..."
  scale_down media tautulli
  delete_pvc media tautulli-data
  delete_pvc media tautulli-cache
  apply_pvc kubernetes/apps/media/tautulli/app/pvc.yaml
  scale_up media tautulli
}

# Migrate Wizarr
migrate_wizarr() {
  echo "Migrating Wizarr..."
  scale_down media wizarr
  delete_pvc media wizarr-data
  apply_pvc kubernetes/apps/media/wizarr/app/pvc.yaml
  scale_up media wizarr
}

# Main function
main() {
  if [ "$1" == "all" ]; then
    migrate_radarr
    migrate_sonarr
    migrate_prowlarr
    migrate_recyclarr
    migrate_tautulli
    migrate_wizarr
  elif [ "$1" == "radarr" ]; then
    migrate_radarr
  elif [ "$1" == "sonarr" ]; then
    migrate_sonarr
  elif [ "$1" == "prowlarr" ]; then
    migrate_prowlarr
  elif [ "$1" == "recyclarr" ]; then
    migrate_recyclarr
  elif [ "$1" == "tautulli" ]; then
    migrate_tautulli
  elif [ "$1" == "wizarr" ]; then
    migrate_wizarr
  else
    echo "Usage: $0 [all|radarr|sonarr|prowlarr|recyclarr|tautulli|wizarr]"
    exit 1
  fi
}

main "$@"
