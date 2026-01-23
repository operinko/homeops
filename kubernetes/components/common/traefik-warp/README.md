# Traefik Warp Middleware

This component installs a Traefik Middleware named `traefik-warp` into the `network` namespace.

## Purpose

The `traefik-warp` plugin resolves the real visitor IP address when Traefik is behind a CDN (Cloudflare or CloudFront). It:

1. **Validates socket IP** against official CDN CIDR ranges
2. **Trusts CDN headers** only when socket IP matches CDN ranges
3. **Sets standard headers**:
   - `X-Real-IP`: Real visitor IP
   - `X-Forwarded-For`: Appends visitor IP to chain
   - `X-Forwarded-Proto`: Normalizes to `http` or `https`
4. **Adds telemetry headers**:
   - `X-Warp-Trusted`: `yes` or `no`
   - `X-Warp-Provider`: `cloudflare`, `cloudfront`, or `unknown`

## Configuration

- **Provider**: `auto` (detects Cloudflare or CloudFront based on socket IP)
- **Auto-refresh**: Enabled (refreshes CDN CIDR ranges every 24h)
- **Debug**: Disabled (set to `true` for troubleshooting)

## Why This Matters

When external traffic comes through Cloudflare Tunnel:
- Without this plugin: Authentik sees tunnel pod IP (10.42.x.x)
- With this plugin: Authentik sees real client IP from `CF-Connecting-IP`

This enables Authentik Expression Policies to distinguish between:
- **Internal clients** (192.168.x.x) → bypass authentication
- **External clients** (public IPs) → require authentication

## Usage

This middleware should be applied **before** `authentik-forward` middleware on routes that need real IP detection:

```yaml
middlewares:
  - traefik-warp@file
  - authentik-forward@file
  - crowdsec-bouncer@file
```

## References

- Plugin: https://github.com/l4rm4nd/traefik-warp
- Version: v1.1.5

