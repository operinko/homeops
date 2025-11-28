# Authentik Expression Policy for Internal IP Bypass

This document describes how to configure Authentik to bypass authentication for internal network clients while maintaining authentication requirements for external clients accessing through Cloudflare Tunnel.

## Problem Statement

When external applications (like Sonarr, Radarr) are accessed from the internal network:
- DNS resolves `external.vaderrp.com` to local gateway IPs (192.168.7.4 and 192.168.7.5)
- Internal clients hit `gateway-public` (192.168.7.5) which has Authentik middleware
- Users are prompted for authentication even though they're on the trusted internal network

## Solution Overview

The solution uses two components:

1. **traefik-warp plugin**: Resolves real client IP from `CF-Connecting-IP` header and sets `X-Forwarded-For`
2. **Authentik Expression Policy**: Bypasses authentication based on source IP address

## Implementation Steps

### 1. Traefik Warp Plugin (Already Configured)

The `traefik-warp` middleware is already configured and applied to all external HTTPRoutes. It:
- Validates socket IP against Cloudflare/CloudFront CIDR ranges
- Trusts `CF-Connecting-IP` header only from verified CDN IPs
- Sets `X-Real-IP` and `X-Forwarded-For` headers with real client IP
- Normalizes `X-Forwarded-Proto` to `http` or `https`

### 2. Authentik Expression Policy Configuration

**Navigate to**: Authentik UI → Customization → Policies → Create

**Policy Type**: Expression Policy

**Name**: `bypass-internal-network`

**Expression**:
```python
# Bypass authentication for all private IP addresses
return ak_client_ip.is_private
```

**Explanation**:
- `ak_client_ip` is an IPv4Address object from `X-Forwarded-For` header (set by traefik-warp)
- `is_private` returns `True` for all RFC 1918 private addresses:
  - 10.0.0.0/8 (includes pod CIDR 10.42.0.0/16)
  - 172.16.0.0/12
  - 192.168.0.0/16 (your LAN)
  - Plus loopback (127.0.0.0/8) and link-local (169.254.0.0/16)
- Internal clients → bypassed
- External clients → Authentik sees their public IP from `CF-Connecting-IP` → requires auth

### 3. Apply Policy to Application

**Navigate to**: Authentik UI → Applications → [Your Application] → Policy Bindings

**Add Binding**:
- **Policy**: `bypass-internal-network`
- **Order**: -100 (execute before other policies)
- **Enabled**: Yes

Repeat for all external applications that should bypass auth for internal clients.

## How It Works

### Internal Client Flow
```
Internal Client (192.168.1.100)
  ↓
DNS: external.vaderrp.com → 192.168.7.5
  ↓
gateway-public (192.168.7.5)
  ↓
traefik-warp: Sets X-Forwarded-For: 192.168.1.100
  ↓
Authentik: ak_client_ip = 192.168.1.100
  ↓
Expression Policy: 192.168.1.100.is_private = True → BYPASS
  ↓
Application (no auth required)
```

### External Client Flow
```
External Client (203.0.113.50)
  ↓
Cloudflare Tunnel
  ↓
Tunnel Pod (10.42.x.x) → Sets CF-Connecting-IP: 203.0.113.50
  ↓
gateway-public (192.168.7.5)
  ↓
traefik-warp: Validates socket IP (10.42.x.x) is trusted
             Sets X-Forwarded-For: 203.0.113.50
  ↓
Authentik: ak_client_ip = 203.0.113.50
  ↓
Expression Policy: 203.0.113.50.is_private = False → REQUIRE AUTH
  ↓
Authentik Login Page
```

## Verification

### Test Internal Access
1. From internal network, access: `https://sonarr.vaderrp.com`
2. Expected: Direct access without authentication prompt

### Test External Access
1. From external network (mobile data, VPN, etc.), access: `https://sonarr.vaderrp.com`
2. Expected: Authentik login page

### Debug Headers
Check Traefik access logs or use a debug endpoint to verify headers:
- `X-Real-IP`: Should show real client IP
- `X-Forwarded-For`: Should show real client IP
- `X-Warp-Trusted`: Should be `yes` for Cloudflare traffic
- `X-Warp-Provider`: Should be `cloudflare` for Cloudflare traffic

## Troubleshooting

### Internal clients still prompted for auth
- Check Authentik policy is applied to the application
- Verify policy order is -100 (executes first)
- Check Traefik logs to confirm `X-Forwarded-For` is set correctly
- Verify `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` includes `10.42.0.0/16` and `192.168.0.0/16`

### External clients bypass auth
- Check traefik-warp is working: `X-Warp-Trusted` should be `yes`
- Verify `X-Forwarded-For` contains public IP, not pod IP
- Check Cloudflare Tunnel is setting `CF-Connecting-IP` header

## Security Considerations

1. **Trust Boundary**: Only trust IPs from verified CDN ranges (handled by traefik-warp)
2. **Header Spoofing**: traefik-warp strips spoofable headers before setting trusted values
3. **Pod CIDR**: Trusting 10.42.0.0/16 is safe because it's internal pod traffic only
4. **LAN CIDR**: Trusting 192.168.0.0/16 assumes your internal network is already secure

## References

- traefik-warp plugin: https://github.com/l4rm4nd/traefik-warp
- Authentik Expression Policies: https://docs.goauthentik.io/docs/policies/expression
- Component: `kubernetes/components/network/traefik-warp/`

