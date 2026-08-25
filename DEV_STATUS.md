# Dev Status

## Status
The HA ingress panel now loads the full donetick SPA end-to-end — assets, locale
files, and API calls all resolve correctly through the ingress-prefixed path, and
signup/login work through ingress with no unexpected errors in the network capture.
See `CHANGES.md` for the full list of fixes that got here.

`single_circle_instance` is now fixed — see below.

## What works
- Full build/deploy loop: `./scripts/deploy.sh` from repo root
- Addon installs and runs in HAOS (NAT VM, `192.168.126.128`); donetick and nginx
  both start cleanly
- Ingress panel loads correctly at the HA sidebar panel URL — verified via HAR
  capture with zero unexpected 404s
- Signup/login flow works through ingress (verified via HAR — the only 4xx codes
  are the expected pre-auth 401s on data queries that fire before the route guard
  redirects to `/login`)

## Fixed: `single_circle_instance` not enforced for password signup
Expected: with `single_circle_instance: true`, a second user signing up should join
the first (and only) circle rather than create their own. Observed: the second user
landed in a new, separate circle.

Traced the addon option → env var → backend config path and it was wired correctly
end-to-end (`single_circle_instance` addon option → `DT_SINGLE_CIRCLE_INSTANCE` env
var → viper picks it up via `SetEnvPrefix("DT")` → `config.SingleCircleInstance` →
`Handler.singleCircleInstance`). The bug was in `donetick/internal/user/handler.go`:
`h.singleCircleInstance` was only checked inside `thirdPartyAuthCallback` (the OAuth2
signup path) — the password-based `signUp` handler (what the ingress panel's signup
form actually calls) unconditionally created a brand new circle for every user,
never consulting the flag at all.

Fixed `signUp` to mirror the OAuth2 path's logic: when `single_circle_instance` is
set, join the shared circle (ID 1), creating it (named "Home") if this is the first
signup. Verified directly against the running addon (`POST /api/v1/auth/` for two
throwaway accounts, then `GET /api/v1/users/profile` for each) — both landed on
`circleID: 1`; test accounts were deleted afterward via `DELETE /api/v1/users/delete`.

## Auth question
Donetick does NOT use HA's native auth. HA ingress provides outer security (must be
logged into HA to reach the ingress URL), but users still need to log into donetick
with its own credentials. For first-time setup: sign up at the donetick login page via
ingress. Options for simpler auth:
- Keep donetick's own username/password auth (simplest, current approach)
- Configure OAuth2 via addon options (donetick supports it; HA doesn't provide OAuth2
  natively — would need an external provider)
- `disable_password_auth: true` disables password login (intended for OAuth2-only setups)

## Ingress architecture
```
Browser → HA ingress gateway (172.30.32.2)
  → nginx :8099 (allow 172.30.32.2 only)
    → sub_filter injects: <script>window.__INGRESS_PATH__="/.../TOKEN"</script>
      → proxies to donetick :2021

Frontend reads window.__INGRESS_PATH__ at startup via Config.js's BASE_PATH export,
used by the router basename, the API client, i18next's locale loadPath, and every
other runtime-constructed absolute URL (OAuth redirect_uri, chore share links, etc).
```

## Network topology (confirmed)
```
172.30.32.2  = supervisor / hassio (confirmed in /etc/hosts inside container)
172.30.33.0  = addon container IP
172.30.32.1  = gateway
```
`allow 172.30.32.2; deny all;` on port 8099 is correct.

## HAOS VM setup notes
- VMware Workstation, **NAT mode** (not bridged — bridged caused networking issues)
- IP: `192.168.126.128` (configured in `.env`, gitignored)
- SSH: `hassio@192.168.126.128:22` (Advanced SSH addon, protection mode OFF)
- One-time after SSH install: `ssh hassio@192.168.126.128 -p 22 "sudo addgroup hassio messagebus"` (grants docker socket access)
- `docker` requires `sudo` as the `hassio` user; deploy.sh uses `sudo docker logs`
- Container name is `app_local_<slug>` (not `addon_local_`)
- Do **not** run `ha store refresh` — it triggers auto-updates and can break the OS
