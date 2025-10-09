#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Talos requires the nodes to be 'Ready=False' before applying resources
function wait_for_nodes() {
    log debug "Waiting for nodes to be available"

    # Skip waiting if all nodes are 'Ready=True'
    if kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        log info "Nodes are available and ready, skipping wait for nodes"
        return
    fi

    # Wait for all nodes to be 'Ready=False'
    until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
        log info "Nodes are not available, waiting for nodes to be available. Retrying in 10 seconds..."
        sleep 10
    done
}

# Namespaces to be applied before the SOPS secrets are installed
function apply_namespaces() {
    log debug "Applying namespaces"

    local -r apps_dir="${ROOT_DIR}/kubernetes/apps"

    if [[ ! -d "${apps_dir}" ]]; then
        log error "Directory does not exist" "directory=${apps_dir}"
    fi

    for app in "${apps_dir}"/*/; do
        namespace=$(basename "${app}")

        # Check if the namespace resources are up-to-date
        if kubectl get namespace "${namespace}" &>/dev/null; then
            log info "Namespace resource is up-to-date" "resource=${namespace}"
            continue
        fi

        # Apply the namespace resources
        if kubectl create namespace "${namespace}" --dry-run=client --output=yaml \
            | kubectl apply --server-side --filename - &>/dev/null;
        then
            log info "Namespace resource applied" "resource=${namespace}"
        else
            log error "Failed to apply namespace resource" "resource=${namespace}"
        fi
    done
}

# SOPS secrets to be applied before the helmfile charts are installed
function apply_sops_secrets() {
    log debug "Applying secrets"

    local -r secrets=(
        "${ROOT_DIR}/bootstrap/github-deploy-key.sops.yaml"
        "${ROOT_DIR}/kubernetes/components/common/sops/cluster-secrets.sops.yaml"
        "${ROOT_DIR}/kubernetes/components/common/sops/sops-age.sops.yaml"
    )

    for secret in "${secrets[@]}"; do
        if [ ! -f "${secret}" ]; then
            log warn "File does not exist" "file=${secret}"
            continue
        fi

        # Check if the secret resources are up-to-date
        if sops exec-file "${secret}" "kubectl --namespace flux-system diff --filename {}" &>/dev/null; then
            log info "Secret resource is up-to-date" "resource=$(basename "${secret}" ".sops.yaml")"
            continue
        fi

        # Apply secret resources
        if sops exec-file "${secret}" "kubectl --namespace flux-system apply --server-side --filename {}" &>/dev/null; then
            log info "Secret resource applied successfully" "resource=$(basename "${secret}" ".sops.yaml")"
        else
            log error "Failed to apply secret resource" "resource=$(basename "${secret}" ".sops.yaml")"
        fi
    done
}

# CRDs to be applied before the helmfile charts are installed
function apply_crds() {
    log debug "Applying CRDs"

    local -r crds=(
        # renovate: datasource=github-releases depName=prometheus-operator/prometheus-operator
        https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.86.0/stripped-down-crds.yaml
        # renovate: datasource=github-releases depName=kubernetes-sigs/external-dns
        #https://raw.githubusercontent.com/kubernetes-sigs/external-dns/refs/tags/v0.19.0/docs/sources/crd/crd-manifest.yaml
        # Traefik CRDs required for Middleware, IngressRoute, etc. Install at bootstrap time.
        # renovate: datasource=github-tags depName=traefik/traefik extractVersion=^v(?<version>\d+\.\d+)
        https://raw.githubusercontent.com/traefik/traefik/v2.10/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
        # Gateway API CRDs are now managed by Flux in kubernetes/components/network/gateway/crds
        # (removed from bootstrap to avoid duplication and conflicts)
    )

    for crd in "${crds[@]}"; do
        if kubectl diff --filename "${crd}" &>/dev/null; then
            log info "CRDs are up-to-date" "crd=${crd}"
            continue
        fi
        if kubectl apply --server-side --filename "${crd}" &>/dev/null; then
            log info "CRDs applied" "crd=${crd}"
        else
            log error "Failed to apply CRDs" "crd=${crd}"
        fi
    done
}

# Apply Helm releases using helmfile
function apply_helm_releases() {
    log debug "Applying Helm releases with helmfile"

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log error "File does not exist" "file=${helmfile_file}"
    fi

    # Common Helmfile apply flags
    local -r hf_flags=(--hide-notes --skip-diff-on-install --suppress-diff --suppress-secrets)

    # Phase 1: Apply all releases except flux-instance so the operator (and its CRDs) install first
    log info "Applying Helm releases (excluding flux-instance)"
    if ! helmfile --file "${helmfile_file}" apply "${hf_flags[@]}" --selector name!=flux-instance; then
        log error "Failed to apply Helm releases (excluding flux-instance)"
    fi

    # Wait for FluxInstance CRD to exist and be established before applying the instance
    local -r flux_crd="fluxinstances.fluxcd.controlplane.io"
    log info "Waiting for CRD to be established" "crd=${flux_crd}"

    # Try for up to ~2 minutes for CRD to appear and become Established
    if ! kubectl get crd "${flux_crd}" &>/dev/null; then
        # Poll for CRD creation
        for i in {1..24}; do
            if kubectl get crd "${flux_crd}" &>/dev/null; then
                break
            fi
            log debug "CRD not found yet, retrying..." "attempt=${i}"
            sleep 5
        done
    fi

    if kubectl get crd "${flux_crd}" &>/dev/null; then
        if ! kubectl wait --for=condition=Established --timeout=120s "crd/${flux_crd}"; then
            log warn "Timed out waiting for CRD to be Established, proceeding anyway" "crd=${flux_crd}"
        fi
    else
        log warn "CRD still not found, proceeding to apply flux-instance (Helm may fail on first try)" "crd=${flux_crd}"
    fi

    # Phase 2: Apply only flux-instance now that CRD should exist
    log info "Applying Helm release: flux-instance"
    if ! helmfile --file "${helmfile_file}" apply "${hf_flags[@]}" --selector name=flux-instance; then
        log error "Failed to apply Helm release flux-instance"
    fi

    log info "Helm releases applied successfully"
}

function main() {
    check_cli helmfile kubectl kustomize sops talhelper yq

    # Apply resources and Helm releases
    wait_for_nodes
    apply_namespaces
    apply_sops_secrets
    apply_crds
    apply_helm_releases

    log info "Congrats! The cluster is bootstrapped and Flux is syncing the Git repository"
}

main "$@"
