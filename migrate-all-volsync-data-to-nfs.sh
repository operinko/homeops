#!/usr/bin/env bash
# This script migrates all VolSync applications with data from iSCSI to NFS storage classes.
# Usage: ./migrate-all-volsync-data-to-nfs.sh [-r]
# Where:
#   -r: Dry run mode (show what would be done without making changes)

set -e

# Default values
DRY_RUN=false

# Parse command line arguments
while getopts "r" opt; do
  case $opt in
    r) DRY_RUN=true ;;
    *) echo "Usage: $0 [-r]" >&2
       exit 1 ;;
  esac
done

# Set colors for output
INFO='\033[0;36m'    # Cyan
SUCCESS='\033[0;32m' # Green
WARNING='\033[0;33m' # Yellow
ERROR='\033[0;31m'   # Red
NC='\033[0m'         # No Color

function write_step() {
  echo -e "${INFO}➡️ $1${NC}"
}

function write_success() {
  echo -e "${SUCCESS}✅ $1${NC}"
}

function write_warning() {
  echo -e "${WARNING}⚠️ $1${NC}"
}

function write_error() {
  echo -e "${ERROR}❌ $1${NC}"
}

# Check if volsync-migrate-data-to-nfs.sh exists
if [ ! -f "./volsync-migrate-data-to-nfs.sh" ]; then
  write_error "volsync-migrate-data-to-nfs.sh not found in the current directory. Exiting."
  exit 1
fi

# Make sure the script is executable
chmod +x ./volsync-migrate-data-to-nfs.sh

# Get all ReplicationSources across all namespaces
write_step "Getting all ReplicationSources across all namespaces..."
REPLICATION_SOURCES=$(kubectl get replicationsource --all-namespaces -o json)
SOURCES_COUNT=$(echo "$REPLICATION_SOURCES" | jq '.items | length')

if [ "$SOURCES_COUNT" -eq 0 ]; then
  write_warning "No ReplicationSources found. Exiting."
  exit 0
fi

write_success "Found $SOURCES_COUNT ReplicationSources"

# Process each ReplicationSource
echo "$REPLICATION_SOURCES" | jq -r '.items[] | .metadata.namespace + " " + .metadata.name' | while read -r line; do
  NAMESPACE=$(echo "$line" | cut -d' ' -f1)
  APP=$(echo "$line" | cut -d' ' -f2)
  
  write_step "Processing application '$APP' in namespace '$NAMESPACE'..."
  
  COMMAND="./volsync-migrate-data-to-nfs.sh -n $NAMESPACE -a $APP"
  if [ "$DRY_RUN" = true ]; then
    COMMAND="$COMMAND -r"
  fi
  
  echo -e "${INFO}Executing: $COMMAND${NC}"
  eval "$COMMAND"
  
  write_success "Completed processing application '$APP' in namespace '$NAMESPACE'"
  echo "-----------------------------------------------------------"
done

write_success "All applications processed successfully"
