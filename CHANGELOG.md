# Changelog

Customer-facing changes to the Broch server, release to release. Versions match
the published image — `ghcr.io/broch-io/broch:<version>`.

This changelog covers what changes for you as an operator: features you can use,
behavior you'll notice, and anything you need to do when upgrading. It is not a
commit log — internal refactors and engineering changes that don't surface in
deployment or use are deliberately omitted.

## 1.28.0

### Added

- **Config-as-code for Share and Access (`broch.yaml` + `broch up`).** Declare every tunnel and access connection you run in a single manifest, then bring them all up — and tear them all down together — with one command and one sign-in, instead of managing each `broch share`/`broch access` process by hand. `broch up --check` validates the plan without connecting.
- **Self-hosted free trial.** New deployments can start a card-upfront free trial directly from first-run setup, with a seat picker capped to your trial allowance and a live countdown once the trial is active.
- **Wildcard DNS diagnostics.** The admin status panel, `broch status`, and `broch doctor` now detect and explain wildcard DNS misconfigurations that would otherwise silently break Share or Access.
- **`broch share --no-rewrite` and group-aware `broch access`.** Opt out of Broch's automatic Host/Referer/cookie rewriting for apps that do their own host-based routing, and connect to every endpoint in a group at once with `broch access <group-name>`.
- **Break-glass recovery for a locked-out IdP.** Set `BROCH_AUTH_CONFIG_RESET=true` to clear a stuck auth configuration at boot and recover admin sign-in after an expired identity-provider client secret.

### Changed

- **License and policy changes take effect immediately.** Deactivating a license or editing/deleting a Share policy now cuts over live sessions and authorization right away, instead of waiting for a reconnect or a cache to expire.
- **License status recovers on its own.** A deployment parked on a rejected or expired license now re-checks daily and heals automatically once renewed — no manual refresh needed. Status displays (grace period, seat caps, billing dates) are also more accurate.
- **More flexible seat management.** Admins can remove their own seat assignment, and anonymized (GDPR-erased) seats no longer count against your seat limit.
- **Quieter, more useful logs.** Framework noise is downgraded, request logs carry a correlation ID and duration for tracing, and console/stdout logging can emit OpenTelemetry-standard attribute names for your log collector. Internal identifiers that could reveal customer counts were removed from log output.
- **Overhauled marketplace deploy experience.** Azure Marketplace now offers a single VM Appliance plan with six DNS/TLS provider choices, three database modes (including a local, eval-oriented option), and a required, strength-checked master key; an equivalent AWS Marketplace CloudFormation listing was added.

### Security

- **CLI is now HTTPS-only.** `--insecure` and `BROCH_INSECURE` have been removed — the CLI only connects to your server over TLS. Custom CA certificates (`BROCH_CA_CERT_PATH`) are also now correctly applied to every connection.
- **Access backend certificates are now validated.** A self-signed or otherwise untrusted certificate on an Access backend is rejected instead of silently proxied.
- **Rate limiting on sign-in and the Share relay.** Login, callback, and session endpoints are limited per client IP, and Share tunnels have default-on flood protection — both non-configurable.
- **`BROCH_MASTER_KEY` strength enforced at startup**, and the CLI's trusted-host store now fails closed instead of open when it can't be read.
- **Observability secrets encrypted at rest**, plus fixes for a denial-of-service vulnerability in the CLI's WebSocket transport and an OpenSSL vulnerability in the `broch-caddy` deploy image.

### Fixed

- **Share tunnels recover instead of dead-ending.** A failed setup no longer leaves a tunnel that looks "connected" but is dead; reconnects now retry indefinitely through server restarts, keepalive actually closes wedged connections, and `broch share` exits non-zero when it gives up for good.
- **Cold-start and delayed-start reliability.** Tunnels now ride out a scaled-to-zero server's cold start on the very first connect (not just on reconnect), and a local service that comes up after the server has idled is no longer orphaned.
- **Sign-in reliability.** Running `broch share` and `broch access` at the same time no longer forces a re-login, and a custom `Authentication:Scopes` value that omits `openid` no longer breaks login.
- **Server boots correctly with an unset `AUTHENTICATION__PROVIDER`**, and `curl` is now bundled in the server image so container healthchecks work out of the box.
- **Admin UI polish.** Save dialogs no longer flash or reopen empty after saving, Access dialogs support building endpoint → group → policy without leaving the dialog, and several validation mismatches between the app and server were fixed.

### Deploy impact

- **CLI is HTTPS-only.** Any saved server URL using `http://` must be changed to `https://` before upgrading the CLI — there is no insecure override.
- **CLI requires Node.js ≥ 22.19.0.** Node.js 22.0–22.18 will crash at runtime with the updated `@broch/cli`; upgrade Node.js first.
- **Access backends need valid certificates.** Endpoints pointing at `https://` backends with self-signed or otherwise invalid certificates will start returning 502 after this upgrade.
- **`BROCH_MASTER_KEY` (and `BrochToken:SigningKey`, if set) must be at least 32 bytes.** A previously-accepted weaker key will now block server startup; keys generated by the deploy template are unaffected.
- **Deactivating a license now immediately ends live sessions.** Share and Access connections are cut over right away rather than being allowed to run to their natural end.
- **New non-configurable rate limits.** Share tunnels are capped at roughly 100 requests/second per tunnel, and login/auth endpoints at 60 requests per 5 minutes per client IP — review this if you run high-throughput webhook tunnels or have many users behind one shared corporate IP.
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
