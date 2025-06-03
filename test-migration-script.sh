#!/bin/bash

# Test script to verify the migration script logic without kubectl

# Mock kubectl function for testing
kubectl() {
    case "$1 $2 $3" in
        "get pvc bazarr")
            if [ "$4" = "-n" ] && [ "$5" = "media" ]; then
                return 0  # PVC exists
            fi
            ;;
        "get pvc recyclarr")
            if [ "$4" = "-n" ] && [ "$5" = "media" ]; then
                return 0  # PVC exists
            fi
            ;;
        "get pvc atuin")
            if [ "$4" = "-n" ] && [ "$5" = "default" ]; then
                return 0  # PVC exists
            fi
            ;;
        "get pvc"*)
            if [[ "$*" == *"-o jsonpath"* ]]; then
                echo "democratic-volsync-nfs"  # Mock storage class
                return 0
            fi
            ;;
    esac
    return 1  # Default: not found
}

# Mock flux function
flux() {
    echo "Mock flux command: $*"
    return 0
}

# Source the migration script functions
source migrate-to-nfs-csi.sh

# Test the get_applications_to_migrate function
echo "Testing get_applications_to_migrate function..."
echo "========================================"

DRY_RUN=true

# Test the function
echo "Calling get_applications_to_migrate..."
apps_output=$(get_applications_to_migrate 2>&1)
exit_code=$?

echo "Exit code: $exit_code"
echo "Raw output:"
echo "$apps_output"

# Convert to array like the main script does
apps=()
while IFS= read -r line; do
    if [ -n "$line" ] && [[ "$line" != *"Scanning for applications"* ]] && [[ "$line" != *"Found:"* ]]; then
        apps+=("$line")
    elif [[ "$line" == *"Found:"* ]]; then
        echo "Discovery: $line"
    fi
done <<< "$apps_output"

echo
echo "Parsed applications (${#apps[@]} total):"
for i in "${!apps[@]}"; do
    echo "  [$i] ${apps[$i]}"
done

echo
echo "Testing array processing..."
for app_full in "${apps[@]}"; do
    namespace="${app_full%/*}"
    app="${app_full#*/}"
    echo "Processing: namespace='$namespace', app='$app'"
done
