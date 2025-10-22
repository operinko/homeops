Traefik CrowdSec Bouncer Middleware

This component installs a Traefik Middleware named `crowdsec-bouncer` into the `network` namespace.

It requires a Secret `traefik-crowdsec-bouncer` with keys:
- lapi_key
- captcha_site_key
- captcha_secret_key

Traefik HelmRelease must mount this secret to:
- /var/run/secrets/crowdsec/lapi_key
- /var/run/secrets/crowdsec/captcha_site_key
- /var/run/secrets/crowdsec/captcha_secret_key

The middleware is configured to:
- Use CrowdSec LAPI at crowdsec-lapi.network.svc.cluster.local:8080
- Use streaming mode
- Read client IP from CF-Connecting-IP
- Trust LAN and in-cluster ranges for bypass
- Use Turnstile captcha

