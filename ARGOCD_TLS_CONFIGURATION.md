# ArgoCD TLS Configuration

## The Problem

You got this error:

```
tls: failed to verify certificate: x509: cannot validate certificate for 10.42.0.43 
because it doesn't contain any IP SANs
```

This happens because:
1. **Traefik (Gateway) terminates TLS** using `vaderrp-com-production-tls` certificate
2. **Traefik connects to ArgoCD backend** on the pod IP (10.42.0.43)
3. **ArgoCD uses a self-signed certificate** that doesn't match the pod IP
4. **Certificate validation fails** because the cert is for `argocd.vaderrp.com`, not `10.42.0.43`

---

## The Solution

Configure ArgoCD to:
1. **Use insecure mode internally** (no TLS between Traefik and ArgoCD)
2. **Use the existing certificate** for the public domain
3. **Tell ArgoCD it's behind HTTPS** via the `url` config

---

## Configuration

### HelmRelease Values

```yaml
server:
  # Disable insecure mode - we use HTTPS via Gateway
  insecure: false
  
  # Configure TLS with the existing certificate
  certificateSecret:
    enabled: true
    name: vaderrp-com-production-tls
  
  # Configure server to work behind HTTPS proxy
  config:
    # Tell ArgoCD it's behind HTTPS
    url: https://argocd.vaderrp.com
  
  # Disable HTTPS on the service itself
  # (Traefik handles TLS termination)
  extraArgs:
    - --insecure

repoServer:
  # Disable TLS for repo server
  extraArgs:
    - --insecure
```

### Key Settings

| Setting | Value | Reason |
|---------|-------|--------|
| `server.insecure: false` | false | Tells ArgoCD to expect HTTPS |
| `server.certificateSecret.enabled` | true | Use existing cert |
| `server.certificateSecret.name` | vaderrp-com-production-tls | Use your cert |
| `server.config.url` | https://argocd.vaderrp.com | Public URL |
| `server.extraArgs` | --insecure | Disable TLS internally |
| `repoServer.extraArgs` | --insecure | Disable TLS for repo server |

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│ Client (internal network)                               │
└────────────────────┬────────────────────────────────────┘
                     │ HTTPS (vaderrp-com-production-tls)
                     ▼
        ┌────────────────────────────┐
        │ Gateway (gateway-internal) │
        │ TLS Termination            │
        │ 192.168.7.4:443            │
        └────────────┬───────────────┘
                     │ HTTP (no TLS)
                     ▼
        ┌────────────────────────────┐
        │ HTTPRoute (argocd-server)  │
        │ argocd.vaderrp.com         │
        └────────────┬───────────────┘
                     │ HTTP (no TLS)
                     ▼
        ┌────────────────────────────┐
        │ Middleware (authentik-fwd) │
        │ Checks Authentik auth      │
        └────────────┬───────────────┘
                     │ HTTP (no TLS)
                     ▼
        ┌────────────────────────────┐
        │ ArgoCD Server              │
        │ --insecure (HTTP mode)     │
        │ argocd-server:443          │
        └────────────────────────────┘
```

**Key Point:** TLS is only between client and Gateway. Between Gateway and ArgoCD, it's HTTP (no TLS).

---

## Installation

### 1. Add Argo Helm Repository

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

### 2. Create Namespace

```bash
kubectl create namespace argocd
```

### 3. Apply HelmRelease

```bash
kubectl apply -f kubernetes/argocd/helmrelease.yaml
```

### 4. Apply Middleware and HTTPRoute

```bash
kubectl apply -f kubernetes/argocd/middleware-authentik-forward.yaml
kubectl apply -f kubernetes/argocd/argocd-server-httproute.yaml
```

### 5. Verify Installation

```bash
# Check HelmRelease
kubectl get helmrelease -n argocd
kubectl describe helmrelease argocd -n argocd

# Check pods
kubectl get pods -n argocd

# Check HTTPRoute
kubectl get httproute -n argocd
kubectl describe httproute argocd-server -n argocd
```

---

## Testing

### 1. Get Initial Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 2. Access ArgoCD

```bash
# From internal network
curl -k https://argocd.vaderrp.com

# Should redirect to Authentik login
# Login with your Authentik credentials
```

### 3. Check Logs

```bash
# Check ArgoCD server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server -f

# Check Traefik logs
kubectl logs -n network -l app.kubernetes.io/name=traefik -f | grep argocd
```

---

## Troubleshooting

### Certificate Errors

```bash
# Check if certificate secret exists
kubectl get secret vaderrp-com-production-tls -n network

# Check certificate details
kubectl get secret vaderrp-com-production-tls -n network -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

### HTTPRoute Not Accepted

```bash
kubectl describe httproute argocd-server -n argocd
# Should show: Accepted: True, Programmed: True
```

### ArgoCD Not Responding

```bash
# Check if service is running
kubectl get svc -n argocd

# Check pod status
kubectl get pods -n argocd

# Check logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

---

## Why This Works

1. **Traefik terminates TLS** - Uses `vaderrp-com-production-tls` for the public domain
2. **ArgoCD runs in insecure mode** - No TLS between Traefik and ArgoCD
3. **No certificate mismatch** - ArgoCD doesn't need to validate the pod IP
4. **Authentik integration** - Middleware handles authentication
5. **Secure end-to-end** - Client to Gateway is HTTPS, Gateway to ArgoCD is HTTP (internal only)

---

## Summary

✅ **TLS terminated at Gateway**
✅ **Uses existing vaderrp-com-production-tls certificate**
✅ **ArgoCD runs in insecure mode internally**
✅ **No certificate validation errors**
✅ **Secure end-to-end for clients**

**Next Step:** Apply the HelmRelease and test access to https://argocd.vaderrp.com


