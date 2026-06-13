# Changelog

Customer-facing changes to the Broch server, release to release. Versions match
the published image — `ghcr.io/broch-io/broch:<version>`. For which deploy
examples support which server version, see [COMPATIBILITY.md](COMPATIBILITY.md).

This changelog covers what changes for you as an operator: features you can use,
behavior you'll notice, and anything you need to do when upgrading. It is not a
commit log — internal refactors and engineering changes that don't surface in
deployment or use are deliberately omitted.

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
