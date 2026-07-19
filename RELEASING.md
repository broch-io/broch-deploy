# How releases land in this repository

This repository is the public home of Broch's deploy templates. Its history is a
sequence of deliberate releases, not day-to-day iteration — every change arrives
through a staged release pipeline:

1. **Development and review happen in an internal staging repository.** Changes
   are developed behind pull-request review (two independent AI reviewers plus
   maintainer review), static gates (`bicep build`, `cfn-lint`, `terraform
   validate`, compose boot tests, `scripts/deploy-lint.py`), and an
   internal-content guard that keeps non-public material out of the release
   surface.
2. **Every template release is validated live before it ships.** The Azure VM
   template is deployed end-to-end into a real subscription — boot to healthy,
   assert, tear down — across all database modes, plus a lifecycle variation
   matrix (redeploy, delete + recreate under the same name, cross-region
   recreation, recovery paths, hostile-input cases).
3. **The release is promoted through a path-scoped, allowlisted filter.** Only
   the public deploy surface (templates, compose stacks, scripts, the public CI
   workflows, and this documentation) can promote; everything else is excluded
   by construction, with independent tripwires re-checking the final diff.
4. **The release lands here as a pull request into `main`.** CodeRabbit reviews
   it independently and the required status checks (template validation, boot
   tests, deploy lint, secret scanning) must pass; the maintainer merges.

The version pinned in `scripts/BROCH_VERSION` is the single source of truth for
the Broch image version across every template — bumped by
`scripts/bump-broch-version.py`, never by hand.

If you find a problem with a template, please open an issue — reports about
redeploy/recovery behavior are especially valuable, and the deploy-lint gate
grows a rule for every class of failure we fix.
