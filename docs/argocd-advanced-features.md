# ArgoCD Advanced Features

This document explains advanced ArgoCD features that can further enhance your GitOps workflow.

## Overview

Three advanced features that can significantly improve your workflow:

1. **Matrix Generator** - Combine multiple generators for complex deployment patterns
2. **Pull Request Generator** - Preview changes in isolated environments before merging
3. **Image Updater** - Automatically update container images when new versions are released

---

## 1. ApplicationSet Matrix Generator 🔀

### What It Does

Combines multiple generators to create a Cartesian product of applications. Think of it as nested loops - for each item from Generator A, it creates applications for all items from Generator B.

### When to Use It

**Good Use Cases:**
- Deploy same apps to multiple clusters (dev/staging/prod)
- Deploy same apps to multiple namespaces with different configs
- Create multiple variants of an app with different parameters
- Multi-tenant deployments

**Your Homelab Use Cases:**
- ❌ **Multiple clusters** - You only have one cluster
- ✅ **Multi-namespace monitoring** - Deploy Prometheus/Grafana to multiple namespaces
- ✅ **Environment variants** - Deploy apps with dev/staging/prod configs in different namespaces
- ⚠️ **Limited value** - Most useful with multiple clusters

### How It Works

```yaml
generators:
  - matrix:
      generators:
        # Generator 1: Environments
        - list:
            elements:
              - env: dev
              - env: prod

        # Generator 2: Applications
        - git:
            directories:
              - path: apps/*
```

**Result**: Creates `2 environments × N apps = 2N Applications`

### Example

See `examples/applicationset-matrix-example.yaml` for a complete example deploying monitoring stack to multiple namespaces.

### Pros & Cons

**Pros:**
- Powerful for multi-cluster/multi-tenant setups
- Reduces duplication
- Centralized configuration

**Cons:**
- Complex to understand and debug
- Can create many applications quickly
- Overkill for single-cluster homelabs
- Harder to customize individual apps

### Recommendation for Your Homelab

**⚠️ Skip for now** - Limited value with a single cluster. Revisit if you add more clusters or need multi-tenant namespaces.

---

## 2. ApplicationSet Pull Request Generator 🔍

### What It Does

Automatically creates preview environments for GitHub Pull Requests. When you open a PR, ArgoCD deploys your changes to an isolated namespace so you can test before merging.

### When to Use It

**Good Use Cases:**
- Test infrastructure changes before merging
- Preview application updates in isolation
- Catch breaking changes early
- Safe experimentation
- Team collaboration (multiple people working on different features)

**Your Homelab Use Cases:**
- ✅ **Test Renovate PRs** - Preview dependency updates before auto-merge
- ✅ **Test major changes** - Try risky changes in isolation
- ✅ **Experiment safely** - Test new apps without affecting production
- ⚠️ **Resource intensive** - Each PR creates full environment

### How It Works

1. You create a PR with changes
2. Add `preview` label to the PR
3. ArgoCD detects the PR and creates an Application
4. Application deploys to `preview-pr-123` namespace
5. You test your changes
6. When PR is merged/closed, preview environment is auto-deleted

### Example Workflow

```bash
# 1. Create PR with changes to Sonarr
git checkout -b update-sonarr
# ... make changes ...
git push origin update-sonarr

# 2. Open PR on GitHub and add "preview" label

# 3. ArgoCD automatically creates:
#    - Application: pr-123-update-sonarr
#    - Namespace: preview-pr-123
#    - Deploys your changes

# 4. Test at: http://sonarr.preview-pr-123.vaderrp.com

# 5. Merge PR → preview environment auto-deleted
```

### Configuration Required

**Prerequisites:**
- GitHub Personal Access Token or GitHub App
- Secret in ArgoCD namespace with token
- Labels on PRs to trigger preview

**Setup Steps:**
1. Create GitHub token with `repo` scope
2. Store in Kubernetes secret
3. Create ApplicationSet with PR generator
4. Add `preview` label to PRs you want to preview

### Example

See `examples/applicationset-pr-generator-example.yaml` for complete examples.

### Pros & Cons

**Pros:**
- Catch issues before merging
- Safe testing environment
- Automatic cleanup
- Great for Renovate PRs
- Reduces production incidents

**Cons:**
- Requires GitHub token
- Uses cluster resources (CPU, memory, storage)
- May need ingress for each preview
- Can be expensive with many PRs
- Complexity in setup

### Recommendation for Your Homelab

**✅ Consider implementing** - Very useful for testing Renovate PRs and major changes. Start with one namespace (e.g., media) to test the concept.

**Resource Impact:**
- Each preview = full app deployment
- With 119 apps, one preview could use significant resources
- Consider filtering to specific namespaces only

---

## 3. ArgoCD Image Updater 🔄

### What It Does

Automatically monitors container registries for new image versions and updates your applications when new versions are released.

### When to Use It

**Good Use Cases:**
- Automatic security patches
- Keep apps up-to-date with upstream
- Reduce manual Renovate PRs
- Rolling tags (`:latest`, `:rolling`)
- Development environments

**Your Homelab Use Cases:**
- ✅ **Media apps** - Auto-update Sonarr, Radarr, etc. (frequent releases)
- ✅ **Rolling tags** - Apps using `:rolling` or `:latest` tags
- ⚠️ **Conflicts with Renovate** - You already use Renovate for updates
- ❌ **Production** - Risky for critical apps (database, auth, ingress)

### How It Works

1. Image Updater polls container registries (GHCR, Docker Hub, etc.)
2. Checks for new images matching your strategy
3. When found, updates the Application manifest
4. Can write back to Git (creates commit) or update in-cluster only
5. ArgoCD syncs the updated image

### Update Strategies

**Semver (Semantic Versioning):**
```yaml
# Update to latest patch version (4.0.x)
argocd-image-updater.argoproj.io/sonarr.update-strategy: semver:~4.0

# Update to latest minor version (4.x.x)
argocd-image-updater.argoproj.io/sonarr.update-strategy: semver:^4.0
```

**Latest Tag:**
```yaml
# Update to latest tag matching pattern
argocd-image-updater.argoproj.io/radarr.update-strategy: latest
argocd-image-updater.argoproj.io/radarr.allow-tags: regexp:^rolling-5\..*$
```

**Digest:**
```yaml
# Update digest for :latest tag (ensures latest build)
argocd-image-updater.argoproj.io/homepage.update-strategy: digest
```

### Example

See `examples/argocd-image-updater-example.yaml` for complete examples.

### Pros & Cons

**Pros:**
- Automatic security updates
- Reduce manual work
- Stay current with upstream
- Git history of all updates
- Great for rolling tags

**Cons:**
- Can break things if upstream has breaking changes
- Conflicts with Renovate (duplicate functionality)
- Requires registry credentials
- May create many commits
- Less control than manual updates

### Recommendation for Your Homelab

**⚠️ Skip for now** - You already use Renovate for dependency updates. Image Updater would create conflicts and duplicate work.

**Alternative Approach:**
- Keep using Renovate for controlled updates
- Use Image Updater only for specific apps with rolling tags
- Or use Image Updater in dev/testing namespaces only

---

## Comparison & Recommendations

### Feature Comparison

| Feature | Complexity | Value for Homelab | Resource Impact | Conflicts |
|---------|-----------|-------------------|-----------------|-----------|
| **Matrix Generator** | High | Low | Low | None |
| **PR Generator** | Medium | High | High | None |
| **Image Updater** | Medium | Low | Low | Renovate |

### Recommended Implementation Order

**For Your Homelab:**

1. **✅ PR Generator** (Highest Value)
   - Start with one namespace (e.g., media)
   - Test Renovate PRs before auto-merge
   - Expand to other namespaces if useful

2. **⚠️ Image Updater** (Optional)
   - Only for apps with rolling tags
   - Or disable Renovate for those apps
   - Consider conflicts carefully

3. **❌ Matrix Generator** (Skip)
   - Limited value with single cluster
   - Revisit if you add more clusters
   - Or if you need multi-tenant namespaces

### Decision: Not Implemented

**Date**: 2025-11-06

After careful analysis, decided **not to implement** any of these advanced features for the following reasons:

**Image Updater**:
- Renovate already handles image updates via PRs
- Would create conflicts and duplicate work
- Renovate's PR-based approach provides better control and approval workflow
- No added value for homelab use case

**PR Generator**:
- Would increase resource pressure significantly
- Risk of conflicts with duplicate instances (e.g., two ArgoCD instances running simultaneously)
- Not useful for infrastructure/GitOps PRs (unlike web development)
- Renovate PRs don't benefit from preview environments
- Complexity outweighs benefits for single-user homelab

**Matrix Generator**:
- No multi-tenant applications
- Single cluster only
- No use case for Cartesian product deployments
- Better suited for enterprise multi-cluster setups

**Conclusion**: Current ArgoCD setup with ApplicationSets, progressive sync, resource hooks, and Renovate integration is optimal for this homelab. These advanced features are excellent for enterprise/team environments but add unnecessary complexity here.

---

## Additional Resources

- [ArgoCD ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)
- [Matrix Generator Examples](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Matrix/)
- [PR Generator Examples](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Pull-Request/)
- [Image Updater Documentation](https://argocd-image-updater.readthedocs.io/)
- [Renovate vs Image Updater Comparison](https://github.com/argoproj/argo-cd/discussions/8285)

