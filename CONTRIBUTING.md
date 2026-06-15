# Contributing to gfx1150-bench

Thanks for considering a contribution. This project follows the
"few defaults applied widely" coding standard locked 2026-04-16. Below
is the minimum you need to know to land a change.

## Quick start

1. Fork and clone.
2. Install [shellcheck](https://www.shellcheck.net) — the only required
   tool (`dnf install ShellCheck` / `apt install shellcheck` /
   `brew install shellcheck`).
3. Make your change in a topic branch: `<type>/<scope>-<short-desc>`
   (e.g. `fix/rocm-env`, `docs/methodology`).
4. Conventional Commits, signed: `git commit -s` (the `-s` adds a
   Signed-off-by footer; the SSH-key signature is added automatically
   from `.gitconfig`).
5. `shellcheck *.sh` locally before pushing — CI runs it at default
   severity on every script and must be clean.
6. Open a PR against `main`. CI must be green.

## Standards we enforce

- **Conventional Commits** at commit-msg time (`feat:`, `fix:`, `docs:`,
  `chore:`, etc.). The pre-commit hook will reject non-conforming
  messages. See https://www.conventionalcommits.org.
- **Signed commits**. Branch protection on `main` rejects unsigned
  commits.
- **CI green**: shellcheck must pass on every `*.sh` script.
- **One concern per PR**. Refactors and feature work are different PRs.

## What we look for in review

- Correctness, security, maintainability, tests. Style is the linter's
  job — don't comment on it.
- A PR description that explains *why*, not just *what*. The diff shows
  what; we want the reasoning.
- Self-review before requesting review. Open your own PR and read it as
  a stranger would.

## Reporting issues

For bugs and feature requests: use the issue templates in
[`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/).

For security issues: see [`SECURITY.md`](SECURITY.md). Do not file
public issues for vulnerabilities.

## Versioning

This repo publishes point-in-time benchmark snapshots. A release is cut
by pushing a tag (`vX.Y.Z`); the release workflow then signs the
artifacts (cosign keyless) and attaches an SBOM + SLSA provenance. There
is no `just` wrapper — tag and push.

## License

By contributing, you agree your contributions will be licensed under the
project's existing license — see [`LICENSE-APACHE`](LICENSE-APACHE) and
[`LICENSE-MIT`](LICENSE-MIT) (or whichever single license this repo is
using; check the README).
