# Kubernetes v1.34.2 Upgrade Notes

## Upgrade Date
Planned: TBD

## Version Information
- **From**: v1.33.5
- **To**: v1.34.2
- **Talos Version**: v1.11.5

## Urgent Upgrade Notes Summary

### 1. Metrics Label Changes ⚠️

Multiple API server and etcd metrics have had their labels changed. This affects monitoring and dashboards.

#### Affected Metrics and Label Changes:

**API Server Cache Metrics:**
- `apiserver_cache_list_fetched_objects_total`
- `apiserver_cache_list_returned_objects_total`
- `apiserver_cache_list_total`
- **Change**: `resource_prefix` label → `group` + `resource` labels

**etcd Request Metrics:**
- `etcd_request_duration_seconds`
- `etcd_requests_total`
- `etcd_request_errors_total`
- **Change**: `type` label → `group` + `resource` labels

**API Server Self-Request Metrics:**
- `apiserver_selfrequest_total`
- **Change**: Added `group` label

**Watch Event Metrics:**
- `apiserver_watch_events_sizes`
- `apiserver_watch_events_total`
- **Change**: `kind` label → `resource` label

**Storage and Watch Cache Metrics:**
- `apiserver_request_body_size_bytes`
- `apiserver_storage_events_received_total`
- `apiserver_storage_list_evaluated_objects_total`
- `apiserver_storage_list_fetched_objects_total`
- `apiserver_storage_list_returned_objects_total`
- `apiserver_storage_list_total`
- `apiserver_watch_cache_events_dispatched_total`
- `apiserver_watch_cache_events_received_total`
- `apiserver_watch_cache_initializations_total`
- `apiserver_watch_cache_resource_version`
- `watch_cache_capacity`
- `apiserver_init_events_total`
- `apiserver_terminated_watchers_total`
- `watch_cache_capacity_increase_total`
- `watch_cache_capacity_decrease_total`
- `apiserver_watch_cache_read_wait_seconds`
- `apiserver_watch_cache_consistent_read_total`
- `apiserver_storage_consistency_checks_total`
- `etcd_bookmark_counts`
- `storage_decode_errors_total`
- **Change**: Extract API group from `resource` label into new `group` label

### 2. Kubelet Cloud Config Flag Removed ✅
- **Status**: Not applicable to this cluster
- **Reason**: Talos-managed cluster doesn't use `--cloud-config` flag

### 3. Static Pod Admission Changes ✅
- **Status**: Not applicable to this cluster
- **Reason**: No custom static pods that reference API objects

### 4. Scheduling Framework API Changes ✅
- **Status**: Not applicable to this cluster
- **Reason**: No custom PreFilter plugins

## Impact Assessment

### Prometheus Alert Rules
✅ **No impact** - Current alert rules don't use any of the affected metrics.

Alert rules use:
- `etcd_server_*` (not affected)
- `etcd_disk_*` (not affected)
- `etcd_mvcc_*` (not affected)
- `etcd_network_*` (not affected)
- `apiserver_request_duration_seconds` (not affected)
- `up{job="kube-*"}` (not affected)

### Grafana Dashboards
⚠️ **Potential impact** - Some dashboard panels may break temporarily.

Affected dashboards (imported from external sources):
- `kubernetes-api-server` (gnetId: 15761)
- `kubernetes-global` (gnetId: 15757)
- `kubernetes-namespaces` (gnetId: 15758)
- `kubernetes-nodes` (gnetId: 15759)
- `kubernetes-pods` (gnetId: 15760)

**Action**: Update dashboard revisions after upgrade if panels show "No data"

## Upgrade Procedure

### Option 1: Using Tuppr (Automated)
1. Uncomment kubernetes-upgrade.yaml in kustomization
2. Commit and push changes
3. ArgoCD will sync and tuppr will handle the upgrade

### Option 2: Manual Upgrade
```bash
# Update talenv.yaml (already done)
# Generate Talos config
task talos:generate-config

# Upgrade Kubernetes
task talos:upgrade-k8s
```

## Post-Upgrade Verification

1. **Check node status:**
   ```bash
   kubectl get nodes
   ```

2. **Verify all pods are running:**
   ```bash
   kubectl get pods -A
   ```

3. **Check Prometheus metrics:**
   ```bash
   kubectl port-forward -n observability svc/prometheus-operated 9090:9090
   # Visit http://localhost:9090 and verify metrics are being scraped
   ```

4. **Review Grafana dashboards:**
   - Check for any "No data" panels
   - Update dashboard revisions if needed

5. **Monitor alerts:**
   ```bash
   kubectl get prometheusrules -A
   ```

## Rollback Plan

If issues occur:
1. Revert git commits
2. ArgoCD will sync back to v1.33.5
3. Or manually downgrade:
   ```bash
   # Update talenv.yaml back to v1.33.5
   task talos:upgrade-k8s
   ```

## References
- [Kubernetes v1.34 Changelog](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.34.md)
- [Talos Kubernetes Upgrade Guide](https://www.talos.dev/latest/kubernetes-guides/upgrading-kubernetes/)

