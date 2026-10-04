# Changelog

Customer-facing changes to the Broch server, release to release. Versions match
the published image — `ghcr.io/broch-io/broch:<version>`.

This changelog covers what changes for you as an operator: features you can use,
behavior you'll notice, and anything you need to do when upgrading. It is not a
commit log — internal refactors and engineering changes that don't surface in
deployment or use are deliberately omitted.

## 1.35.0

### Added

- **Check your configuration before you deploy.** The image now has two commands that read your environment and configuration files as the server does at startup, without starting the server or touching the database or network. Because they don't read the database, they can't see settings saved in the admin UI. `--check-config` (optionally with `--json`) lists every problem and exits non-zero if there are any. `--describe-config` prints the rules the server enforces as JSON, so your deploy tooling can validate settings itself.
- **Billing and seat options match your license.** Licenses that aren't billed through Stripe no longer show a Manage Billing button, and the Configuration page explains why. Update seat counts is hidden when there is no subscription, and disabled with a reason while a subscription is trialing or paused. When the licensing service refuses a seat change, you now see its message instead of a generic error.

### Changed

- **Azure Marketplace wizard catches unsupported characters up front.** Fields that feed the VM's configuration now reject a single quote, a line break or a trailing backslash as you type, instead of failing after Review + create.
- **Lower Application Insights volume.** Four noisy HTTP client metrics are no longer sent to Application Insights, which reduces ingestion volume. Request duration, server metrics, traces, requests and dependencies are unchanged.
- **Clearer licensing-service errors.** If the server can't reach the licensing service, the admin UI says so, instead of showing "unexpected error".

### Fixed

- **Share's public link appears only when it works.** The `broch share` CLI used to print the Public link slightly before the server could serve it, so a request in that gap could get a 502. The link now appears once the tunnel is ready. A newer CLI against an older server connects as before, and older CLIs are unaffected.
- **Startup accepts sign-in settings saved in the admin UI.** Startup now checks your effective sign-in configuration: environment values plus anything saved in the admin UI. A deployment whose Auth0 audience was saved in the app but left blank in the environment no longer refuses to start, and a blank value saved in the app no longer overrides a valid environment value.
- **License state no longer carries over between keys.** Clearing or replacing the license key now also clears the cached license state, so one license's billing options can't show up under the next.

### Deploy impact

- **Configuration keys:** no operator config keys were added, renamed, or removed in this release.
- **Stricter startup validation.** The server now checks all settings up front, so some configurations that previously started and failed later now fail at startup. Run `--check-config` against your configuration before upgrading. These cases now fail at startup with a clear message:
  - an unknown `AUTHENTICATION__PROVIDER`, or a numeric or comma-separated value for any setting that takes a fixed set of names
  - a non-boolean `LICENSE__AIRGAPPED`
  - an unparseable `SHARE__PROXYACTIVITYTIMEOUT`
  - invalid values for `CENTRALSERVER__VALIDATIONTIMEOUTSECONDS`, the sign-in token settings, `BROCHTELEMETRY__PROVIDER` (including a value saved in the app), and the tunnel limit settings (`API__MAXTUNNELS`, `BROCH__MAXTUNNELS`)

  Previously, a bad `CENTRALSERVER__VALIDATIONTIMEOUTSECONDS` or sign-in token setting only failed later, at license refresh or first sign-in. Only the first error is reported at startup, in the same order `--check-config` lists them.

  Startup also checks sign-in, logging and telemetry settings saved in the admin UI, which `--check-config` can't see. Before upgrading, open Configuration and confirm the saved sign-in settings are complete for your provider (for example, an OAuth client secret where your provider needs one). A saved value that 1.34.0 tolerated can stop 1.35.0 from starting.
- **Billing portal errors changed.** For a license that isn't billed through Stripe, the billing portal request now returns a 409 "not billed through Stripe" instead of a generic 502 "temporarily unavailable". Update any scripts that depend on the old response. The system info response also now reports whether billing and seat changes are available.
- **Share link readiness needs a CLI update to take effect.** The fix for the early Public link needs both this server and the newer `broch` CLI. Upgrading the server image does not update an existing CLI install — update it separately.

### Deploy templates

The templates in this repository now pin 1.35.0 and carry these changes. Read the ones for your target before you upgrade:

- **Azure Container Apps (Terraform) — upgrading replaces the database.** The module now runs Postgres on a private network and uses the azurerm 5.x provider. Upgrading a deployment made with the earlier module **replaces the database server, and its data is lost**: run `pg_dump` against the old server first (the restore must run from a host inside the VNet), and expect to redo the custom-domain binding, because the Container Apps environment is replaced too. The database server now carries `prevent_destroy`, so the plan stops until you deliberately remove that line. Run `terraform init -upgrade`, and register the `Microsoft.ContainerService` resource provider. Details in the module README.
- **AWS ECS (Terraform):** moves to the AWS provider 6.x (run `terraform init -upgrade`). RDS deletion protection is now on by default; set `rds_deletion_protection = false` before an intentional destroy.
- **DigitalOcean (Terraform):** the data volume carries `prevent_destroy`, and `admin_roles` now defaults to `broch_admin`.
- **Azure VM (Bicep and Marketplace):** secrets are now written to the VM's `.env` exactly as supplied. Earlier versions let Docker Compose alter a value containing `$`, ` #` or leading/trailing spaces. If your master key or local database password contains one of those, redeploy with the value the running containers actually received (the module README shows how to read it). In `Local` database mode the password may no longer contain `;`, `"` or leading/trailing spaces. `authAdminRoles` now defaults to `broch_admin`.
- **Azure Container Apps (Bicep):** `authProvider` no longer defaults to `AzureAd`; set it explicitly in your parameters file.
- **AWS (CloudFormation):** `DbInstanceClass` accepts any RDS instance class name instead of a fixed list. The stack now validates `AuthProvider` and the Auth0 audience strictly, so an existing stack with a differently-cased provider name or stray whitespace in the audience needs that fixed on its next update.
- **All templates** refuse, before deploying, the settings Broch itself would refuse at startup. `scripts/config-contract.py` checks a template against a Broch image locally; see its usage notes for the tools it needs.

## 1.34.0

### Added

- **Purchases no longer get stuck during setup.** A purchase that can't be resolved right away is now kept safe in the background and checked again automatically, without blocking first-run setup or a new checkout. Setup shows a clear "Waiting for payment" state with the checkout's expiry, and Cancel checkout is always available. You can enter a license key on any setup screen, dismiss purchase notices, retry activation of a saved key, and remove a saved key. If a second purchase is made while a license is already active, the key is not applied and you're shown a notice so you can request a refund.
- **Faster bulk transfers through Share and Access.** Large transfers through tunnels now sustain higher throughput.
- **One AWS template per identity provider.** The AWS CloudFormation deploy now comes as a separate template for Azure AD, Okta, Auth0 and generic OIDC, each with its own Launch Stack link and only that provider's sign-in fields.
- **`broch access --fallback-local-port`.** In the separately installed `broch` CLI, Access can now fall back to another free local port when the preferred one is already taken, and reuses that port on reconnect.

### Changed

- **Lower memory use in the `broch` CLI.** The CLI has a smaller memory footprint, including when telemetry is configured. As with other CLI changes, upgrading the server image does not update an existing CLI install — update it separately.
- **Azure Marketplace wizard requires a Let's Encrypt email.** The email is now required in every certificate mode, and the wizard notes that a new deployment can take 3–10 minutes to become ready (when `/healthz` returns 200). The wizard also enforces the server's length limits for the Auth0 audience (500 characters) and client ID (255 characters).

### Fixed

- **Checkout cancel and retry.** Cancelling a checkout and starting over is safe even when setup is open in several tabs, and a paid purchase is no longer dropped when its key was already claimed.
- **CLI stability.** The CLI no longer errors on a tunnel channel that closes while disconnecting.
- **AWS first boot no longer hangs intermittently.** The stack now waits for the instance to be running before it attaches the Elastic IP.

### Deploy impact

- **Auth0 now requires an audience.** Deployments using Auth0 must set `AUTHENTICATION__AUDIENCE` to the identifier of an Auth0 API (with the user-access grant the API needs), or the server will refuse to start. Broch no longer falls back to the client ID, which Auth0 rejected with "Service not found" and which would not have issued role information anyway. The admin auth-configuration API returns a 400 for Auth0 without an audience, and a blank audience set in the admin UI makes sign-in fail with a configuration error naming the setting. Okta and other providers are unaffected.
- **Configuration keys:** no operator config keys were added, renamed, or removed in this release.
- **Checkout is refused while a license is active or a key is saved.** Starting a new checkout now returns a 409 in that case; use the billing portal for seat changes and renewals. A second purchase made anyway is never applied.
- **Purchase claiming now runs inside the server.** Purchases are claimed by the server itself (every few seconds while a checkout is open, and every few hours for unresolved ones), not by the browser, so the browser-driven purchase polling endpoint is gone. Claiming only runs while a replica is up, and is skipped on air-gapped deployments. Any scripts or tooling calling the old polling endpoint or relying on the old setup status values must be updated; setup status now reports purchases and notices separately.
- **Database migration on upgrade.** A new migration adds purchase tracking storage and runs automatically. The previous in-flight purchase column is kept and in-flight purchase state is not carried over, so a checkout that was open at upgrade time may need to be restarted.
- **A Let's Encrypt email is now required on every deploy template.** Supply `acmeEmail` (Azure), `AcmeEmail` (AWS) or `CADDY_ACME_EMAIL` (Docker Compose `with-postgres` and `with-postgres-external`) when you next redeploy, update the stack, or run `docker compose up`. A blank value now fails the deploy, instead of starting a server whose Caddy can't run (no HTTPS, no automatic DNS records). The Azure Marketplace wizard requires it too.
- **AWS stacks now create a Lambda function.** A small function and its IAM role wait for the instance to be running before the Elastic IP is attached. Creating or updating the stack therefore needs Lambda create rights, and a least-privilege deployer needs `iam:PassRole` for the stack's roles. The function's log group (`/aws/lambda/<stack>-…`) outlives `delete-stack`; see Teardown in the AWS README. To update an existing stack, deploy the template for your `AuthProvider` (`template-<provider>-shared-shared.yaml`).

## 1.33.0

### Added

- **Long-lived Share requests stay open.** Long-polls, Server-Sent Events with gaps, and slow uploads proxied through Share are no longer cut off after ~100 seconds of inactivity. The idle limit is now configurable via `SHARE__PROXYACTIVITYTIMEOUT` (default 15 minutes).

### Changed

- **User accounts are created at sign-in, not first tunnel use.** Anyone who signs in now shows up as an account to admins right away, even before opening a Share or Access tunnel; on broch-hosted trials, the per-user trial clock now starts at sign-up. Display names up to 256 characters (matching Microsoft Entra ID's limit) are supported.
- **Azure Marketplace database guidance strengthened.** The connection-string tooltip in the deployment wizard now recommends full certificate-and-hostname verification (`VerifyFull`) instead of encryption-only, with guidance for private CAs and IP-based connections.
- **AWS Marketplace listing paused.** New AWS deployments should use the CloudFormation template directly rather than the Marketplace listing.

### Security

- **CLI security fixes.** The next stable release of the separately installed `broch` CLI binds cached login credentials to the deployment they were issued for, closes a Windows command-injection risk in how it opens login URLs in your browser, keeps replayed requests in the request inspector on HTTPS, and narrows the scope of authenticated tunnel peer forwarding. As with past CLI security updates, upgrading the server image does not update an existing CLI install — update it separately.
- **Share access to loopback targets now requires an explicit Share Rule.** Previously a loopback (localhost) target was reachable without a dedicated rule; it now needs one with no service assigned, and the rejection message says so.
- **More reliable session and access revocation.** Refresh tokens and step-up ("recent authentication") evidence are now bound to the session that issued them. Revoking a seat, changing a Share/Access policy, expiring a trial, or an Access credential expiring now reliably and promptly disconnects affected sessions even under many concurrent connections, closing gaps where one slow or hung client could delay revocation for everyone else.
- **Go dependency vulnerabilities fixed in the `broch-caddy` deploy image.** Several HIGH-severity vulnerabilities in bundled Go networking libraries are patched.

### Fixed

- **Login right after an identity-provider signing-key rotation.** The very first login immediately following an IdP key rotation could fail once; it now recovers automatically instead of returning an error.
- **License reactivation and activation races.** Reactivating a deactivated deployment now correctly restores service; a queued activation can no longer reclaim a seat that a concurrent deactivation just freed, and changing your license key mid-deactivation now returns a clear conflict instead of a misleading error.
- **Access TLS certificates on Windows.** Certificates for Access TLS termination could fail to persist across restarts when the backend uses Windows Schannel; they are now stored and reloaded correctly.
- **`broch share --no-rewrite` Host header.** Fixed a case where the original Host header wasn't preserved when forwarding to the local service.

### Deploy impact

- **Loopback Share targets need a Share Rule.** If a Share target points at a loopback address (e.g. `localhost`) and relied on being reachable without a dedicated rule, add a Share Rule for it (with no service assigned) — otherwise it will be rejected with a 403 after upgrading.
- **A session established before this upgrade may need a one-time re-login.** Stricter binding of refresh tokens to session identity means a pre-existing session that doesn't carry the expected binding will be asked to sign in again on its next refresh; this resolves itself automatically and requires no admin action.

## 1.32.0

### Security

- **CLI HTTP transport security updates.** The separately installed `broch` CLI `1.32.0` bundles updated HTTP transport dependencies that address vulnerabilities known when this release shipped. Upgrading the server image does not update an existing CLI installation: if you use CLI `1.31.0` or earlier, run `npm install -g @broch/cli@1.32.0` (or install a newer stable CLI release) separately.

## 1.31.0

### Changed

- **Safer Azure Marketplace recovery redeploys.** The version field on the Redeploy form now tells you exactly what to enter (your current version, found in the RG Deployments history or Admin System) and only accepts a real `X.Y.Z` version or `latest` — preventing a recovery redeploy from a newer listing's wizard from silently jumping your deployment across an irreversible database-migration boundary.

### Security

- **c-ares vulnerability fixed in the `broch-caddy` deploy image.**

### Fixed

- **More reliable Azure Marketplace Key Vault recovery.** If a soft-deleted vault's name no longer matches what the current template computes (for example after a region change, a renamed vault, or an auth-mode switch), the wizard no longer hard-fails — it simply creates a fresh vault instead. The recovery notice also now correctly appears for backup-vault matches, not just primary.

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
