# ArgoCD HTTPRoute Implementation Guide

## Overview

This guide shows how to expose ArgoCD using the same **Gateway API (HTTPRoute)** pattern you use for all your other apps.

---

## Step 1: Create ArgoCD Namespace and Install

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD (using Helm or manifests)
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd

# Verify installation
kubectl get pods -n argocd
```

---

## Step 2: Create HTTPRoute for ArgoCD Server

Create `kubernetes/argocd/argocd-server-httproute.yaml`:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
  labels:
    route.scope: internal
  annotations:
    external-dns.alpha.kubernetes.io/public: "false"
spec:
  parentRefs:
    - name: gateway-internal
      namespace: network
  hostnames: ["argocd.vaderrp.com"]
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: authentik-forward
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: crowdsec-bouncer
      backendRefs:
        - name: argocd-server
          port: 443
```

**Key Points:**
- `port: 443` - ArgoCD server runs on HTTPS
- Traefik automatically uses HTTPS when port 443 is specified
- `gateway-internal` - Internal-only access (like Grafana)
- `authentik-forward` - SSO authentication
- `crowdsec-bouncer` - DDoS/attack protection

---

## Step 3: Apply HTTPRoute

```bash
# Apply the HTTPRoute
kubectl apply -f kubernetes/argocd/argocd-server-httproute.yaml

# Verify it's created
kubectl get httproute -n argocd
# Expected output:
# NAME              HOSTNAMES                 AGE
# argocd-server     ["argocd.vaderrp.com"]    5s

# Check status
kubectl describe httproute argocd-server -n argocd
# Should show:
# Status:
#   Parents:
#     - Conditions:
#         - Message: Accepted
#           Reason: Accepted
#           Status: "True"
#           Type: Accepted
#         - Message: Programmed
#           Reason: Programmed
#           Status: "True"
#           Type: Programmed
```

---

## Step 4: Verify Traefik Picked Up the Route

```bash
# Check Traefik logs
kubectl logs -n network -l app.kubernetes.io/name=traefik -f | grep argocd

# Expected output:
# level=info msg="Configuring route for HTTPRoute" namespace=argocd name=argocd-server
```

---

## Step 5: Test Access

```bash
# From internal network
curl -k https://argocd.vaderrp.com

# Should redirect to Authentik login page
# If you see Authentik login, it's working!

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

---

## Step 6: Configure ArgoCD for HTTPS

ArgoCD needs to know it's behind HTTPS. Update the ArgoCD server configuration:

```bash
# Edit ArgoCD ConfigMap
kubectl edit configmap argocd-cmd-params-cm -n argocd
```

Add these settings:

```yaml
data:
  server.insecure: "false"
  server.basehref: /
  server.rootpath: /
  server.disable.auth: "false"
```

Or via Helm values:

```yaml
# values.yaml
server:
  insecure: false
  basehref: /
  rootpath: /
  disableAuth: false
```

---

## Step 7: Configure Authentik SSO (Optional but Recommended)

### Create OIDC Application in Authentik

1. Go to Authentik admin panel
2. Create new OIDC Provider:
   - Name: ArgoCD
   - Client ID: `argocd`
   - Client Secret: (generate)
   - Redirect URIs: `https://argocd.vaderrp.com/auth/callback`

3. Create Application:
   - Name: ArgoCD
   - Slug: argocd
   - Provider: ArgoCD (OIDC)

### Configure ArgoCD OIDC

```bash
# Edit ArgoCD ConfigMap
kubectl edit configmap argocd-cmd-params-cm -n argocd
```

Add:

```yaml
data:
  oidc.config: |
    name: Authentik
    issuer: https://auth.vaderrp.com/application/o/argocd/
    clientID: argocd
    clientSecret: $oidc.authentik.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
    requestedIDTokenClaims:
      - groups
```

Create secret:

```bash
kubectl create secret generic argocd-oidc-secret \
  -n argocd \
  --from-literal=oidc.authentik.clientSecret=YOUR_CLIENT_SECRET
```

---

## Step 8: Verify Everything Works

```bash
# Check all ArgoCD pods running
kubectl get pods -n argocd

# Check HTTPRoute status
kubectl get httproute -n argocd -o wide

# Check Traefik routes
kubectl logs -n network -l app.kubernetes.io/name=traefik | grep argocd

# Test access
curl -k https://argocd.vaderrp.com
# Should redirect to Authentik login

# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server -f
```

---

## Troubleshooting

### HTTPRoute Not Accepted

```bash
# Check HTTPRoute status
kubectl describe httproute argocd-server -n argocd

# Common issues:
# 1. Gateway doesn't exist
kubectl get gateway -n network

# 2. Hostname doesn't match gateway listener
kubectl describe gateway gateway-internal -n network

# 3. Port mismatch
# ArgoCD server runs on 443, make sure port: 443 in HTTPRoute
```

### Can't Access ArgoCD

```bash
# Check if service exists
kubectl get svc -n argocd | grep argocd-server

# Check service endpoints
kubectl get endpoints -n argocd argocd-server

# Check Traefik logs
kubectl logs -n network -l app.kubernetes.io/name=traefik -f

# Test direct connection
kubectl port-forward -n argocd svc/argocd-server 8443:443
curl -k https://localhost:8443
```

### Authentik Redirect Loop

```bash
# Check ArgoCD OIDC config
kubectl get configmap argocd-cmd-params-cm -n argocd -o yaml | grep -A 10 oidc

# Verify Authentik provider settings:
# - Redirect URI must be: https://argocd.vaderrp.com/auth/callback
# - Client ID and Secret must match

# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server | grep -i oidc
```

---

## File Structure

```
kubernetes/
├── argocd/
│   ├── argocd-server-httproute.yaml    # ← Create this
│   ├── applications/
│   │   ├── root.yaml
│   │   ├── storage/
│   │   ├── network/
│   │   ├── media/
│   │   └── tools/
│   └── kustomization.yaml
```

---

## Summary

✅ **HTTPRoute created for ArgoCD**
✅ **Uses same pattern as your other apps**
✅ **Integrated with Authentik SSO**
✅ **Protected by CrowdSec**
✅ **Accessible at https://argocd.vaderrp.com**

**Next Steps:**
1. Create the HTTPRoute file
2. Apply it to your cluster
3. Test access
4. Configure Authentik SSO (optional)
5. Start migrating apps to ArgoCD


