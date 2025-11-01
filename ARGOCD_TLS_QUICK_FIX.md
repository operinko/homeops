# ArgoCD TLS Quick Fix

## The Error

```
tls: failed to verify certificate: x509: cannot validate certificate for 10.42.0.43 
because it doesn't contain any IP SANs
```

## The Root Cause

- **Traefik (Gateway)** terminates TLS using `vaderrp-com-production-tls`
- **Traefik connects to ArgoCD** on the pod IP (10.42.0.43)
- **ArgoCD uses a self-signed cert** that doesn't match the pod IP
- **Certificate validation fails** because the cert is for `argocd.vaderrp.com`, not `10.42.0.43`

## The Solution

**Run ArgoCD in insecure mode internally** (no TLS between Traefik and ArgoCD). TLS is only between client and Gateway.

---

## What You Need

### 1. HelmRelease: `kubernetes/argocd/helmrelease.yaml`

Key settings:
```yaml
server:
  insecure: false                    # Tell ArgoCD to expect HTTPS
  certificateSecret:
    enabled: true
    name: vaderrp-com-production-tls # Use your existing cert
  config:
    url: https://argocd.vaderrp.com  # Public URL
  extraArgs:
    - --insecure                     # Disable TLS internally

repoServer:
  extraArgs:
    - --insecure                     # Disable TLS for repo server
```

### 2. Middleware: `kubernetes/argocd/middleware-authentik-forward.yaml`
(Already created)

### 3. HTTPRoute: `kubernetes/argocd/argocd-server-httproute.yaml`
(Already created)

---

## Installation Steps

### 1. Add Argo Helm Repository

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

### 2. Create Namespace

```bash
kubectl create namespace argocd
```

### 3. Apply All Files

```bash
# Apply HelmRelease (installs ArgoCD)
kubectl apply -f kubernetes/argocd/helmrelease.yaml

# Apply middleware and HTTPRoute
kubectl apply -f kubernetes/argocd/middleware-authentik-forward.yaml
kubectl apply -f kubernetes/argocd/argocd-server-httproute.yaml
```

### 4. Wait for Installation

```bash
# Watch HelmRelease
kubectl get helmrelease -n argocd -w

# Check pods
kubectl get pods -n argocd
```

### 5. Verify HTTPRoute

```bash
kubectl describe httproute argocd-server -n argocd
# Should show: Accepted: True, Programmed: True
```

### 6. Test Access

```bash
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Access ArgoCD
curl -k https://argocd.vaderrp.com
# Should redirect to Authentik login
```

---

## How It Works

```
Client (HTTPS)
    ↓
Gateway (TLS Termination)
    ↓ (HTTP - no TLS)
HTTPRoute
    ↓ (HTTP - no TLS)
Middleware (Authentik)
    ↓ (HTTP - no TLS)
ArgoCD Server (--insecure mode)
```

**Key:** TLS only between client and Gateway. Internal traffic is HTTP.

---

## Why This Works

1. ✅ **No certificate mismatch** - ArgoCD doesn't validate pod IP
2. ✅ **Uses existing certificate** - `vaderrp-com-production-tls`
3. ✅ **Secure for clients** - HTTPS from client to Gateway
4. ✅ **Internal traffic safe** - Only accessible from within cluster
5. ✅ **Authentik protected** - Middleware handles authentication

---

## Files Created

- ✅ `kubernetes/argocd/helmrelease.yaml` - ArgoCD installation with TLS config
- ✅ `kubernetes/argocd/middleware-authentik-forward.yaml` - Authentik middleware
- ✅ `kubernetes/argocd/argocd-server-httproute.yaml` - HTTPRoute for public access
- ✅ `ARGOCD_TLS_CONFIGURATION.md` - Detailed TLS guide

---

## Next Steps

1. Apply the HelmRelease
2. Wait for ArgoCD pods to be ready
3. Verify HTTPRoute is accepted
4. Test access to https://argocd.vaderrp.com
5. Login with Authentik credentials


