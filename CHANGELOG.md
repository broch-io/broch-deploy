# Changelog

Customer-facing changes to the Broch server, release to release. Versions match
the published image — `ghcr.io/broch-io/broch:<version>`.

This changelog covers what changes for you as an operator: features you can use,
behavior you'll notice, and anything you need to do when upgrading. It is not a
commit log — internal refactors and engineering changes that don't surface in
deployment or use are deliberately omitted.

## 1.30.0

### Added

- **Trusted reverse-proxy CIDR seeding on first boot.** Set `API__TRUSTEDPROXYCIDRS` to your ingress/proxy network and new deployments will trust forwarded headers from it automatically — no more manually configuring Trusted Proxy CIDRs in the admin UI just to get correct client-IP attribution in audit logs, rate limiting, and checkout redirects. An admin-configured value always takes precedence on later boots.

### Changed

- **More resilient Azure Marketplace deployments.** The wizard now checks PostgreSQL region availability before deploying (avoiding partial failures), automatically detects and recovers soft-deleted Key Vaults when you recreate a resource group under the same name, and points you at Azure's native Redeploy button as the one clear way to retry a failed deployment. The default tunnel subdomain is now `broch` (e.g. `broch.yourzone.com`) instead of `tunnels`.

### Security

- **Closed a login denial-of-service.** Behind a reverse proxy that isn't marked as trusted, an unauthenticated attacker could previously exhaust the shared login rate limit and lock out every user; the limiter now tracks real clients separately.
- **Login now fails closed on backend errors.** A transient database fault during sign-in could previously issue a degraded session token that bypassed seat revocation and consumed an extra licensed seat; it's now rejected with a retryable error instead.
- **`broch share --inspect` is hardened against DNS-rebinding attacks** that could otherwise exfiltrate captured request/response data through a malicious webpage.

### Fixed

- **More reliable tunnel reconnects.** Fixed a race that could kill an in-flight Share/Access reconnect mid-handshake, and a CLI crash under bursty multi-port forwarding load.
- **Creating a Share policy with a duplicate or over-length name now returns a clear error** instead of a generic server failure.
- **Azure Marketplace warns about delegated DNS zones.** If your domain's zone is delegated to a non-Azure DNS provider, the wizard now tells you automatic A-record management won't apply and to create the records yourself.

### Deploy impact

- **Sessions issued during a past authentication-backend fault are invalidated.** Login now always stamps an identity issuer on the token; any rare pre-existing session that lacked one (only possible from a past transient database fault during sign-in) will be signed out and asked to re-authenticate. This resolves itself on next login — no action needed.

## 1.29.0

### Added

- **Automatic DNS management for VM appliance deployments.** Self-hosted VM appliances (Azure, AWS) can now automatically create and self-heal the apex and wildcard DNS A records that Share/Access tunnels need, removing the manual post-deploy DNS step. The Azure Marketplace listing now asks for your DNS zone and tunnel subdomain (instead of a single hostname), with an Auto/Manual toggle for record management.

### Changed

- **More complete audit trail.** Purchase and billing-portal actions, and the Share-registry-removal count recorded during seat eviction, now appear in the audit trail — closing gaps for compliance-focused deployments.

### Fixed

- **Telemetry service name on VM deployments.** App Insights previously showed no application name for VM-hosted deployments; logs and traces now report a consistent name, and the admin UI shows a single Service Name field instead of two overlapping ones.

### Deploy impact

- **`CONNECTIONSTRINGS__DEFAULTCONNECTION` is no longer read.** The server now reads `CONNECTIONSTRINGS__BROCHCONNECTION` only. If your deployment sets only the legacy `DefaultConnection` variable, set `BrochConnection` before upgrading or the server will fail to start.
- **Automatic DNS record management may activate on upgrade.** If your deployment already uses automatic (DNS-01) certificate issuance, upgrading the `broch-caddy` image also enables automatic creation and maintenance of your apex and wildcard A records in that DNS zone. BYO-certificate deployments are unaffected.

## 1.28.0

### Added

- **Config-as-code for Share and Access (`broch.yaml` + `broch up`).** Declare every tunnel and access connection you run in a single manifest, then bring them all up — and tear them all down together — with one command and one sign-in, instead of managing each `broch share`/`broch access` process by hand. `broch up --check` validates the plan without connecting.

### Changed

- **Quieter, more useful logs.** Framework noise is downgraded, request logs carry a correlation ID and duration for tracing, and console/stdout logging can emit OpenTelemetry-standard attribute names for your log collector. Internal identifiers that could reveal customer counts were removed from log output.
- **Overhauled marketplace deploy experience.** Azure Marketplace now offers a single VM Appliance plan with six DNS/TLS provider choices, three database modes (including a local, eval-oriented option), and a required, strength-checked master key; an equivalent AWS Marketplace CloudFormation listing was added.

### Security

- **The CLI's trusted-host store now fails closed.** If the store can't be read, connections are refused instead of silently trusting the server's host key.
- **OpenSSL vulnerability fixed in the `broch-caddy` deploy image.**

### Fixed

- **Cold-start and delayed-start reliability.** Tunnels now ride out a scaled-to-zero server's cold start on the very first connect (not just on reconnect), and a local service that comes up after the server has idled is no longer orphaned.
- **Admin UI polish.** Access dialogs support building endpoint → group → policy without leaving the dialog, and several validation mismatches between the app and server were fixed.

### Deploy impact

- **`BrochToken:SigningKey` (if set) must be at least 32 bytes.** A previously-accepted weaker signing key now blocks server startup, matching the `BROCH_MASTER_KEY` floor introduced in 1.26.0.
- **`CentralServer:ApiUrl` has been removed.** The licensing API endpoint is now fixed per release channel; if you had this set, it's now silently ignored — review this config change.

## 1.27.0

### Security

- **CLI vulnerability fixes.** The `broch` CLI patches three HIGH-severity vulnerabilities in its HTTP transport layer: denial of service via WebSocket and a potential man-in-the-middle attack via SOCKS5 TLS. Update your CLI installation to receive these fixes.

## 1.26.0

### Added

- **Free trial.** New deployments are offered a card-upfront free trial in the first-run setup — "Start your free trial" alongside "Buy now". The trial runs until the 1st of the following month (at least 15 days); a live countdown banner appears once the trial is active.
- **Wildcard DNS diagnostics.** The admin status panel, `broch status`, and `broch doctor` now detect and report when the wildcard DNS required for Share or Access tunnels is not resolving correctly, with remediation guidance.
- **`broch share --no-rewrite`.** Opt-in flag to forward requests to your local service without Broch rewriting Host, Referer, Location, or cookies — for apps that do their own host-based routing or expect the public hostname.
- **`broch access` accepts group names.** `broch access <group-name>` now connects to every endpoint in that group at once. Short names shown by `broch services` also work directly as targets.
- **Break-glass for IdP lockout.** Set `BROCH_AUTH_CONFIG_RESET=true` to clear a stuck persisted auth configuration at boot — the recovery path when an expired IdP client secret locks you out of your own deployment. Also: `curl` is now included in the server image so container healthchecks work without a custom base.

### Changed

- **License enforcement is now immediate.** Deactivating a license or clearing the license key now terminates all live Share and Access sessions right away, not on their next reconnect.
- **License auto-recovers after renewal.** A deployment parked on a rejected or expired license now re-probes the licensing server once per day. A renewed or restored license heals automatically without requiring a manual Refresh.
- **Share policy changes take effect immediately.** Editing or deleting a Share policy now invalidates the server's authorization cache instantly; the previous window where a deleted policy could still authorize reconnects is closed.
- **Admins can remove their own seat assignment.** The 403 on deleting or anonymizing your own seat is lifted — admin access is governed by your IdP role claim, not by the seat row.
- **Anonymized seats no longer count against your seat limit.**

### Security

- **CLI requires HTTPS.** The `broch` CLI now rejects `http://` server URLs outright. `BROCH_CA_CERT_PATH` custom CA certificates are also now correctly applied to all TLS and WebSocket connections (previously ignored).
- **Rate limiting on auth and tunnel endpoints.** Login, callback, and session-token endpoints are now rate-limited per client IP (60 requests / 5 minutes). Share tunnel URLs have default-on flood protection (~100 req/s per tunnel).
- **Observability secrets encrypted at rest.** DataDog API key, OTLP headers, AppInsights connection string, and Seq server URL are now wrapped with AES-256-GCM in the database; existing plaintext values self-heal on next write.
- **`BROCH_MASTER_KEY` entropy enforced at startup.** Keys shorter than 32 bytes are rejected with an actionable error message naming the remedy.
- **Access HTTPS backends require valid certificates.** A self-signed or untrusted backend certificate now returns 502 instead of silently accepting the connection.

### Fixed

- **Admin save dialogs no longer reopen after saving.** A loading-state race caused the empty Add dialog to reappear after every successful save or delete in the admin tabs.
- **Server boots correctly with an empty `AUTHENTICATION__PROVIDER`.** Docker Compose templates that pass unset IdP variables as empty strings no longer crash on startup.
- **OIDC login failures on clean deployments.** A custom `AUTHENTICATION__SCOPES` that omitted `openid` — or used Entra's `.default` — prevented login. Required OIDC scopes are now always included regardless of the operator-supplied value.
- **Dead Share tunnels after setup failures.** A transient error during tunnel setup (database blip, invalid claims) previously left the SSH session open, so the CLI showed "connected" while every request 502'd. The session is now closed with a reconnect signal.
- **Connectivity and session reliability.** `broch share` and `broch access` running concurrently no longer force a re-login (token refreshes now coalesce server-side). `broch share` exits non-zero when reconnection is permanently abandoned. SSH keepalive now actually closes wedged connections. Reverse-proxy 502/503s during server restarts are retried indefinitely. Cold-start wake budget raised to 120 seconds for scale-to-zero deployments. `broch share` on macOS no longer incorrectly reports a service as down when it binds IPv4 only.

### Deploy impact

- **CLI requires HTTPS.** Any `BROCH_SERVER_URL` or saved server URL using `http://` must be changed to `https://` before upgrading the CLI. There is no insecure override; the `--insecure` flag and `BROCH_INSECURE` environment variable have been removed.
- **CLI requires Node.js ≥ 22.19.0.** Node.js 22.0–22.18 will crash at runtime with the updated `@broch/cli`. Upgrade Node.js before upgrading the CLI.
- **Access HTTPS backends.** Endpoints that target `https://` backends using self-signed or otherwise invalid certificates will return 502 after this upgrade. Ensure the backend presents a certificate trusted by the system CA store, or configure the endpoint to use `http://` if TLS is terminated elsewhere.
- **`BROCH_MASTER_KEY` entropy floor.** If you manually set `BROCH_MASTER_KEY` to a value shorter than 32 bytes, the server will refuse to start. Keys generated by the deploy template are unaffected.
- **Database migrations.** Two additive, non-breaking migrations run automatically on first boot. You cannot downgrade to a prior image after upgrading.

## 1.24.0

### Changed

- The manual air-gapped license-token import has been removed from License
  settings. Licenses activate in-app after sign-in.

## 1.23.0

### Changed

- License checkout now runs through Broch's branded payment domain,
  `payment.broch.io`.
- Subscription-agreement acceptance now distinguishes onboarding, grace-period,
  and renewal-notice states.

### Security

- Access TLS termination now **fails closed** when no certificate is configured,
  preventing accidental plaintext exposure.

### Fixed

- Resolved a cold-start deadlock affecting deployments that use Access TLS
  termination.

### Deploy impact

- If you restrict outbound traffic, allow `payment.broch.io` so in-app license
  checkout can reach Stripe.
- If you use Access TLS termination, confirm a certificate is configured — the
  server now refuses to start that mode without one.
