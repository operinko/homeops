# AGENTS.md — Homeops

Kubernetes home-lab GitOps repository. Talos Linux cluster managed with Flux, Helm, and SOPS.

## Build & Task Commands

This project uses **Taskfile** (`task`) and **just** as task runners. Install tools via `mise install`.

```bash
task                          # List all available tasks
task reconcile                # Force Flux reconcile (GitRepository + all Kustomizations)
task kubernetes:cleanse-pods  # Delete Failed/Pending/Succeeded pods cluster-wide
task kubernetes:browse-pvc NS=<ns> CLAIM=<pvc>  # Mount PVC to temp container for inspection
task kubernetes:node-shell NODE=<name>           # Open shell on a node
task volsync:snapshot NS=<ns> APP=<app>          # Trigger VolSync snapshot
task volsync:restore NS=<ns> APP=<app>           # Restore VolSync backup (scales down first)
task talos:generate-config    # Generate Talos machine configs via talhelper
task talos:apply-node IP=<ip> MODE=<mode>        # Apply Talos config to node
task bootstrap:talos          # Full Talos cluster bootstrap
task bootstrap:apps           # Bootstrap ArgoCD and Flux apps
```

### Validation & Linting

There is no CI lint/test pipeline. Validate locally before committing:

```bash
yamllint .                    # Lint all YAML (config: .yamllint)
kubeconform -strict -ignore-missing-schemas kubernetes/  # Validate K8s manifests
shellcheck scripts/**/*.sh    # Lint shell scripts (config: .shellcheckrc)
```

## Repository Structure

```
kubernetes/
├── apps/<namespace>/<app>/app/   # App manifests (helmrelease, ocirepository, etc.)
├── apps/<namespace>/<app>/ks.yaml  # Flux Kustomization per app
├── components/                     # Reusable Kustomize components
├── flux/cluster/                   # Cluster-wide Flux config
└── flux/meta/                      # Flux meta (OCI sources, etc.)
talos/                              # Talos Linux machine configs (Jinja2 templates)
bootstrap/                          # Cluster bootstrap (helmfile, deploy keys)
scripts/                            # Shell/Python utility scripts
.taskfiles/                         # Taskfile includes (kubernetes, talos, volsync, bootstrap)
```

### App Directory Convention

Each app lives at `kubernetes/apps/<namespace>/<app-name>/` with:
- `ks.yaml` — Flux Kustomization (always in flux-system namespace)
- `app/helmrelease.yaml` — HelmRelease manifest
- `app/ocirepository.yaml` — OCI chart source
- `app/external-secret.yaml` — ExternalSecret (Bitwarden via ClusterSecretStore)
- `app/httproute.yaml` — Gateway API HTTPRoute for ingress
- `app/pvc.yaml` — PersistentVolumeClaim if needed
- `app/kustomization.yaml` — Lists all resources in the app directory

## Git Conventions

**NEVER auto-commit.** All commits follow Conventional Commits format.

### Commit Format

```
type(component): description
```

- **Types**: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`
- **Capitalization**: Nordic style — only first word and proper nouns capitalized
- **Proper nouns**: Helm, Kubernetes, Flux, Talos, mise, SOPS, Homeops
- **Branch naming**: `feature/descriptive_name` from `main`
- **Merge strategy**: Squash merge preferred

## YAML Style Guide

All YAML in this repo follows these conventions:

- **Indentation**: 2 spaces (set in `.editorconfig`)
- **Document separator**: Always start files with `---`
- **Max line length**: 200 chars (warning level, per `.yamllint`)
- **Document-start marker**: Not required (disabled in yamllint)
- **Truthy values**: `true`/`false`/`on`/`off` are allowed bare
- **Boolean-like strings**: Quote strings that could be parsed as booleans: `"true"`, `"True"`
- **Inline compact syntax**: Use for simple objects: `{ drop: ["ALL"] }`, `{ type: RuntimeDefault }`
- **Inline arrays**: Use for single-item lists: `["ReadWriteOnce"]`
- **No trailing whitespace** (except in Markdown files)
- **Final newline**: Always
- **Comments**: At least 1 space between content and inline comment

### Kubernetes-Specific YAML

- **yaml-language-server schema comments**: Add at top of files when a schema URL is available
- **YAML anchors**: Use `&name`/`*name` for repeated values (e.g., ports, probes)
- **Labels**: Always include `app.kubernetes.io/name` via Flux `commonMetadata`
- **Image tags**: Include full sha256 digest (`image:tag@sha256:...`)
- **Timezone**: `Europe/Helsinki` (via `TZ` env var)

## HelmRelease Conventions

Uses [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) chart heavily:

- `apiVersion: helm.toolkit.fluxcd.io/v2`
- `spec.interval: 30m`, `spec.maxHistory: 2`
- `spec.chartRef` pointing to an OCIRepository (not inline chart)
- Install + upgrade remediation: `retries: 3`
- Security context pattern: `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `runAsNonRoot: true`, `drop: ["ALL"]`, `seccompProfile: RuntimeDefault`, `fsGroupChangePolicy: OnRootMismatch`
- Always set `resources.requests` and `resources.limits` (memory limits 2-4x requests typical)
- Secret refs: `{{ .Release.Name }}-secret`
- NFS mounts for shared media/downloads

## Flux Kustomization (ks.yaml) Conventions

- `apiVersion: kustomize.toolkit.fluxcd.io/v1`
- Always in `flux-system` namespace
- `spec.decryption.provider: sops`
- `spec.targetNamespace` set to actual app namespace
- `spec.prune: true`
- `spec.sourceRef: GitRepository/flux-system`
- `spec.interval: 30m`, `retryInterval: 1m`, `timeout: 5m`
- `commonMetadata.labels` with `app.kubernetes.io/name`
- VolSync apps use `postBuild.substitute` for `APP`, `VOLSYNC_CAPACITY`, etc.
- Components referenced via relative paths: `../../../../components/volsync-kopia`

## ExternalSecret Conventions

- `apiVersion: external-secrets.io/v1`
- `refreshInterval: 1h`
- `target.creationPolicy: Owner`, `target.deletionPolicy: Retain`
- ClusterSecretStore refs: `bitwarden-fields` (custom fields), `bitwarden-login` (credentials)
- Bitwarden item UUIDs as `remoteRef.key`

## HTTPRoute / Gateway API Conventions

- `apiVersion: gateway.networking.k8s.io/v1`
- Labels: `route.scope: external` or `route.scope: internal`
- Annotations for `external-dns.alpha.kubernetes.io/target`, Gatus monitoring, Gethomepage integration
- `parentRefs` to named Gateway in `network` namespace
- Domain: `vaderrp.com`
- Traefik middleware filters referenced as `ExtensionRef`

## Secrets & Encryption

- **SOPS** with **age** encryption for all `*.sops.yaml` files
- Encrypted regex: `data|stringData` for Kubernetes secrets
- Key file: `SOPS_AGE_KEY_FILE` env var (set by mise)
- Patterns: `talos/secrets.sops.yaml`, `bootstrap/*.sops.yaml`, `kubernetes/**/*.sops.yaml`

## Tool Versions

Managed via `.mise.toml`. Key tools: `kubectl`, `talosctl`, `helm` (v4.1.1), `task`, `sops`, `age`, `kubeconform`, `kustomize`, `yq`, `jq`, `helmfile`, `talhelper`, `cilium-cli`, `cloudflared`.

## Shell Scripts

- Shell: `bash` with `set -euo pipefail` (via justfile and Taskfile)
- ShellCheck: SC1091 and SC2155 disabled (`.shellcheckrc`)
- Indentation: 4 spaces for `.sh` files (`.editorconfig`)

## Templating

- **minijinja-cli** for Jinja2 templates (`.j2` extension)
- Config: `autoescape=none`, `trim-blocks=true`, `lstrip-blocks=true`, env vars available
- Used for: Talos machine configs, VolSync restore manifests, bootstrap resources
