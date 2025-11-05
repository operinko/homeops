# ArgoCD Notifications Configuration

This directory contains ArgoCD notification configuration for alerting on application sync status and health changes.

## Current Status

✅ **Notifications Controller**: Enabled  
⏳ **Notification Service**: Not configured (requires webhook/token)

## Quick Setup

### Option 1: Slack Notifications

1. **Create a Slack App**:
   - Go to https://api.slack.com/apps
   - Create a new app
   - Add OAuth scope: `chat:write`
   - Install app to workspace
   - Copy the Bot User OAuth Token

2. **Store token in Bitwarden**:
   - Add token to Bitwarden item
   - Note the item ID and field name

3. **Create ExternalSecret**:
   ```yaml
   ---
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: argocd-notifications-secret
     namespace: argocd
   spec:
     refreshInterval: 1h
     target:
       name: argocd-notifications-secret
       creationPolicy: Owner
       deletionPolicy: Retain
     data:
       - secretKey: slack-token
         sourceRef:
           storeRef:
             name: bitwarden-fields
             kind: ClusterSecretStore
         remoteRef:
           key: <your-bitwarden-item-id>
           property: slack-token
   ```

4. **Update ConfigMap** to add Slack service:
   ```yaml
   # Add to argocd-notifications-cm.yaml under data:
   service.slack: |
     token: $slack-token
   ```

5. **Subscribe applications** by adding annotation:
   ```yaml
   metadata:
     annotations:
       notifications.argoproj.io/subscribe.on-sync-failed.slack: <channel-name>
       notifications.argoproj.io/subscribe.on-health-degraded.slack: <channel-name>
   ```

### Option 2: Discord Notifications

1. **Create Discord Webhook**:
   - Go to Server Settings → Integrations → Webhooks
   - Create webhook and copy URL

2. **Store webhook in Bitwarden**

3. **Create ExternalSecret** (similar to Slack)

4. **Update ConfigMap**:
   ```yaml
   service.webhook.discord: |
     url: $discord-webhook-url
     headers:
     - name: Content-Type
       value: application/json
   ```

## Notification Triggers

The following triggers are configured:

- **on-deployed**: Application is synced and healthy
- **on-health-degraded**: Application health is degraded
- **on-sync-failed**: Sync operation failed
- **on-sync-running**: Sync operation in progress
- **on-sync-status-unknown**: Sync status is unknown
- **on-sync-succeeded**: Sync operation succeeded

## Subscribing Applications

### Global Subscriptions (All Apps)

Add to AppProject:
```yaml
spec:
  syncWindows:
    - kind: allow
      schedule: '* * * * *'
      duration: 1h
      applications:
        - '*'
      namespaces:
        - '*'
  # Add default subscriptions
  defaultSubscriptions:
    - on-sync-failed
    - on-health-degraded
```

### Per-Application Subscriptions

Add annotations to Application:
```yaml
metadata:
  annotations:
    notifications.argoproj.io/subscribe.on-sync-failed.slack: homelab-alerts
    notifications.argoproj.io/subscribe.on-health-degraded.slack: homelab-alerts
```

## Testing Notifications

Test notification delivery:
```bash
# Test Slack notification
argocd admin notifications template notify \
  app-sync-failed \
  --recipient slack:homelab-alerts

# Test Discord notification
argocd admin notifications template notify \
  app-sync-failed \
  --recipient discord:webhook
```

## Troubleshooting

Check notification controller logs:
```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-notifications-controller
```

Verify ConfigMap:
```bash
kubectl get cm argocd-notifications-cm -n argocd -o yaml
```

Verify Secret:
```bash
kubectl get secret argocd-notifications-secret -n argocd
```

## References

- [ArgoCD Notifications Documentation](https://argocd-notifications.readthedocs.io/)
- [Notification Services](https://argocd-notifications.readthedocs.io/en/stable/services/overview/)
- [Notification Triggers](https://argocd-notifications.readthedocs.io/en/stable/triggers/)
- [Notification Templates](https://argocd-notifications.readthedocs.io/en/stable/templates/)

