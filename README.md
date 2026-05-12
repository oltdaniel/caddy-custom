# Custom Caddy build & release

Builds [Caddy](https://caddyserver.com) with a curated plugin set, packages
it as binary tarballs, `.deb`, `.apk`, and multi-arch Docker images, then
publishes the result to either a [Forgejo](https://forgejo.org) instance
or GitHub. Driven by a single config file: [build.yaml](build.yaml).

## AI Disclaimer

This repository was bootstrapped and largely written with [Claude
Code](https://claude.com/claude-code). Since my primary use case
is automating custom Caddy packaging within my homelab, I'm
comfortable with AI-assisted code generation and the resulting
codebase size.

However, all AI-generated output undergoes human review and validation
through automated test suites or manual testing before merging.

## Quick start

```sh
./build.sh tools # download yq, nfpm, and xcaddy into ./tools/
./build.sh all # build every format enabled in build.yaml
./release.sh # publish to the configured provider
```

In CI, the workflows in [.forgejo/workflows](.forgejo/workflows) and
[.github/workflows](.github/workflows) do exactly this on every push to
`main`.

## How versioning works

The published package version is computed at build time from
`caddy.version` plus `caddy.version_suffix`:

| `version_suffix` | Resolves to | Notes |
|-|-|-|
| `"auto"` (default)  | `<caddy.version>.<YYYYMMDD>.<commit-count>`  | Same commit produces the same version, so the already-published check skips rebuild. |
| `""` | `<caddy.version>` | No suffix. |
| `"X"` (anything else) | `<caddy.version>.X` | Literal; digits/letters/dots only. |

So with `caddy.version: 2.11.2`, `version_suffix: auto`, and 42 commits
in the repo today, you get `2.11.2.20260508.42`. Re-running the same
commit yields the same version, and the check job below short-circuits.

The nfpm `release` field (the `-1` in `caddy_<ver>-1_amd64.deb`, `-r1`
in the `.apk`) is hardcoded to `1`. All uniqueness lives in the version
itself.

> If `auto` runs outside a git repo or against a shallow clone, the
> commit count falls back to `0` and rebuilds will collide. CI workflows
> clone with `fetch-depth: 0` to avoid this.

## Providers

The release backend is selected by `release.provider` in `build.yaml`,
with the `RELEASE_PROVIDER` env var taking precedence. Each CI workflow
sets the env explicitly so it stays self-contained.

Both providers create a Release tagged `v<pkg_version>` with binary,
deb, and apk attached as assets, so users get the same discovery
surface either way. The provider-specific extras differ:

| Format | forgejo | github |
|-|-|-|
| binary | generic registry + release asset | release asset |
| deb | debian registry + release asset  | release asset |
| apk | alpine registry + release asset  | release asset |
| docker | container registry | `ghcr.io` |
| Release page | yes | yes |

Re-uploading a same-named asset replaces the existing one on both
providers, so re-running a workflow on the same commit is a no-op.

### Container image naming

| Backend | Image URL |
|-|-|
| forgejo | `<forgejo-host>/<release.forgejo.owner>/<docker.image>` |
| github  | `ghcr.io/<release.github.owner-lowercased>/<release.github.container_image \|\| docker.image>` |

On GitHub, `container_image` is the whole path after the owner and may
be a single name or `/`-separated segments. Both forms are valid:

| `container_image` | Resulting URL |
|-|-|
| `caddy-custom` | `ghcr.io/oltdaniel/caddy-custom` |
| `caddy-custom/server`  | `ghcr.io/oltdaniel/caddy-custom/server`|

When the leading segment matches a repo under the same owner, GitHub
auto-links the package to that repo (visibility on the repo page,
permissions inheritance). So the common patterns are:

- A top-level package whose name happens to be a repo (e.g.
  `caddy-custom` with repo `oltdaniel/caddy-custom`) — auto-linked.
- A repo-scoped package (e.g. `caddy-custom/server`) — auto-linked to
  the `caddy-custom` repo as a sub-package called `server`.

The `release.github.repo` field (used for the Release page) is
independent — it doesn't constrain where the image lives.

### Token scopes

| Provider | Env var | Required scopes |
|-|-|-|
| forgejo | `FORGEJO_TOKEN` | `write:package` (package + container registries) **and** `write:repository` (releases + asset uploads) |
| github | `GITHUB_TOKEN` | `contents: write` (releases) **and** `packages: write` (ghcr) |

For just `release.sh check`, read scopes (`read:package` +
`read:repository` on Forgejo; default `GITHUB_TOKEN` on GitHub) are
enough — the check job runs without a write-scoped token if the
registry/repo is publicly readable.

On the GitHub workflow, `GITHUB_TOKEN` is auto-provided; the
`permissions` block at the top of the workflow declares the two scopes.
On the Forgejo workflow, the token is supplied via the `RELEASE_TOKEN`
secret.

## Installing & upgrading

How to consume the published artifacts, by format. Examples use the
values currently in [build.yaml](build.yaml) (forgejo host
`codeberg.org`, owner `oltdaniel`, package name `caddy-custom`).
Substitute `<pkg_version>` with a real version (e.g. `2.11.0.20260512.42`)
and swap `amd64` / `x86_64` for your architecture as needed.

### Binary tarball

Forgejo (generic registry):
```sh
curl -fsSL -o caddy.tar.gz \
  https://codeberg.org/api/packages/oltdaniel/generic/caddy-custom/<pkg_version>/caddy_<pkg_version>_linux_amd64.tar.gz
tar -xzf caddy.tar.gz caddy
sudo install -m 755 caddy /usr/local/bin/
```

GitHub (release asset):
```sh
curl -fsSL -o caddy.tar.gz \
  https://github.com/oltdaniel/caddy-custom/releases/download/v<pkg_version>/caddy_<pkg_version>_linux_amd64.tar.gz
tar -xzf caddy.tar.gz caddy
sudo install -m 755 caddy /usr/local/bin/
```

Upgrade: re-run the same commands with a newer `<pkg_version>`. There
is no package manager — the binary is just overwritten.

### Debian (`.deb`)

Forgejo (debian registry, integrates with `apt`):
```sh
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://codeberg.org/api/packages/oltdaniel/debian/repository.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/caddy-custom.gpg
echo "deb [signed-by=/etc/apt/keyrings/caddy-custom.gpg] https://codeberg.org/api/packages/oltdaniel/debian stable main" \
  | sudo tee /etc/apt/sources.list.d/caddy-custom.list
sudo apt update
sudo apt install caddy-custom
```

Upgrade: `sudo apt update && sudo apt upgrade caddy-custom`.

GitHub (release asset, manual install):
```sh
curl -fsSL -o caddy.deb \
  https://github.com/oltdaniel/caddy-custom/releases/download/v<pkg_version>/caddy-custom_<pkg_version>-1_amd64.deb
sudo apt install ./caddy.deb
```

Upgrade: download the new `.deb` and run `sudo apt install ./caddy.deb`
again — `apt` detects the higher version and upgrades in place.

### Alpine (`.apk`)

Forgejo (alpine registry, integrates with `apk`):
```sh
curl -fsSL -o /etc/apk/keys/caddy-custom.rsa.pub \
  https://codeberg.org/api/packages/oltdaniel/alpine/key
echo "https://codeberg.org/api/packages/oltdaniel/alpine/v3/caddy-custom" \
  | sudo tee -a /etc/apk/repositories
sudo apk update
sudo apk add caddy-custom
```

Upgrade: `sudo apk update && sudo apk upgrade caddy-custom`.

GitHub (release asset, manual install):
```sh
curl -fsSL -o caddy.apk \
  https://github.com/oltdaniel/caddy-custom/releases/download/v<pkg_version>/caddy-custom_<pkg_version>-r1_x86_64.apk
sudo apk add --allow-untrusted caddy.apk
```

Upgrade: re-run the same commands with a newer `<pkg_version>`. The
`--allow-untrusted` flag is required because the standalone `.apk`
isn't signed against any key in `/etc/apk/keys/`.

> **OpenRC service.** The apk already ships `/etc/init.d/caddy`, so enable
> and start it directly:
> ```sh
> rc-update add caddy default
> rc-service caddy start
> ```
> Alpine community's [`caddy-openrc`](https://pkgs.alpinelinux.org/package/edge/community/x86_64/caddy-openrc)
> contains the same init script packaged standalone (no hard dependency on
> the upstream `caddy` binary). If you prefer to have it owned by the
> upstream package, install with `sudo apk add --force-overwrite caddy-openrc` —
> the file contents are byte-identical to ours, so apk only emits an
> overwrite warning.

### Docker

Forgejo container registry:
```sh
docker pull codeberg.org/oltdaniel/caddy-custom:latest
```

GitHub `ghcr.io`:
```sh
docker pull ghcr.io/oltdaniel/caddy-custom:latest
```

Both registries publish a multi-arch manifest, so `docker pull`
auto-selects the right platform. Upgrade is another `docker pull`
(plus a container restart). Pin to `:<pkg_version>` instead of
`:latest` if you want reproducible deployments.

## CI flow

Both workflows follow the same two-job shape:

1. **`check`** — runs `./release.sh check`, which queries the provider
 for the current `pkg_version` and outputs `published=true|false`.
 Only needs `bash`, `curl`, `yq`.
2. **`build-and-publish`** — gated on `published != 'true'`. Runs
 `./build.sh all` then `./release.sh`. The whole job is skipped (no
 runner allocated) when the version already exists.

The result: pushing the same commit twice does no work the second time;
pushing a new commit always builds because the commit count differs.

A separate `auto-update` workflow runs on a monthly schedule. It calls
[`check-updates.sh`](check-updates.sh) to detect new upstream releases
(Caddy, xcaddy, plugins, yq, nfpm) and new content in the tracked
`dist/` sources, then either opens a rolling PR or commits directly to
`main` depending on `auto_update.mode`.

> On **GitHub**, `auto_update.mode: pr` additionally requires the
> repository setting *Settings → Actions → General → Workflow
> permissions → Allow GitHub Actions to create and approve pull
> requests* to be enabled. Without it, the workflow fails at PR-open
> time with a 403 even when the token scopes are correct. On
> **Forgejo**, the token scopes listed above (`write:repository`) are
> sufficient — no extra repo-level toggle.

## Reproducibility and pinning

All external dependencies are pinned to achieve reproducible builds.

**Caddy.** Pinned by release tag. Set `caddy.version` to an explicit
semver (e.g., `"2.11.2"`), not `"latest"`. Resolved via `go.sum` during
the xcaddy build, so integrity is cryptographically verified by Go.

**Plugins.** Each plugin in `xcaddy.plugins` *must* include a version
tag (preferred: `@vX.Y.Z`; fallback: `@<commit-sha>` for projects
without release tags). Bare module paths are rejected at build time.
Example:

```yaml
plugins:
  - github.com/caddy-dns/cloudflare@v0.2.4
  - github.com/some-plugin/name@abc123def456
```

**Build tools (yq, nfpm, xcaddy).** All three pinned by version +
per-architecture SHA256 in [lib/tools.sh](lib/tools.sh). Downloads are
verified against the hash before use. [`check-updates.sh`](check-updates.sh)
proposes new versions with their hashes together, keeping the pins in
sync. xcaddy's hash is computed locally from the downloaded tarball
(upstream publishes SHA-512 only); yq and nfpm use the SHA-256
`checksums.txt` from their releases. The Go toolchain is still required
at build time because xcaddy invokes `go build` to produce the Caddy
binary — it is no longer needed to install xcaddy itself.

**`dist/` content.** Files imported from
[caddyserver/dist](https://github.com/caddyserver/dist) and
[alpinelinux/aports](https://github.com/alpinelinux/aports) are pinned
by commit SHA in `build.yaml` under `dist.*`. The update checker fetches
each tracked file from upstream, diffs it against the local copy, and
on `--apply` rewrites the changed file and bumps the pin.

**Container image.** The base image (`docker.base_image`) is
intentionally *tag*-pinned but *not* digest-pinned. The Dockerfile runs
`apk add` from alpine's repos, which floats independently of the base
digest — a digest pin would be misleading. Container freshness comes
from the monthly rebuild, not from pinning. The Caddy binary *inside*
the container is pinned and SHA256-verified as described above.

## Configuration surface

All configuration lives in [build.yaml](build.yaml). The most common
knobs:

- `caddy.version` — upstream Caddy version. Either `"latest"` (resolves
  to the current `caddyserver/caddy` release tag at build time) or an
  explicit semver like `"2.11.2"`. Pre-release tags (`"2.12.0-beta1"`)
  are allowed; branches, commit SHAs, and `"nightly"` are rejected
  because the resulting `pkg_version` has to be deb/apk/Docker-safe.
- `xcaddy.plugins` — `--with` modules. Versions and replacements
  supported per [xcaddy](https://github.com/caddyserver/xcaddy)'s syntax.
- `architectures[]` — comment out rows you don't need; each row produces
  one binary, optionally one deb, one apk, and one Docker platform.
- `formats.*` — toggle binary / deb / apk / docker on or off. The same
  flag gates both the build (`build.sh all`) and the publish
  (`release.sh` with no targets); a format that's `false` is skipped
  end-to-end.
- `release.provider` — `forgejo` or `github`.
- `auto_update.mode` — `pr` (rolling PR) or `auto` (commit to `main`).

## Local development

```sh
./build.sh tools # download yq/nfpm/xcaddy (SHA256-verified)
./build.sh binary # per-arch binaries into ./out/binaries/
./build.sh deb apk # nfpm packages into ./out/packages/
./build.sh docker # local Docker image
./build.sh clean # rm -rf ./out/

./release.sh check # is this pkg_version already published?
RELEASE_PROVIDER=github ./release.sh check # ask the other backend
./release.sh binary deb # publish only those targets
```

`build.sh` and `release.sh` are intentionally independent. There is no
combined entry point — CI workflows orchestrate the two-step flow
explicitly.

## Tests

The scripts in [tests/](tests/) exercise the produced artifacts on a
host with the matching runtime available:

| Script | What it checks |
|-|-|
| `tests/binary.sh` | Tarball extracts, binary runs, `caddy version` includes the pinned plugins. |
| `tests/deb.sh` | `.deb` installs into a Debian container, service starts, removes cleanly. |
| `tests/apk.sh` | `.apk` installs into an Alpine container, OpenRC init script works. |
| `tests/docker.sh` | Image starts, default Caddyfile resolves, welcome page is served. |

These are run by hand or in CI before publishing — they are not part of
the default `build.sh all` target.

## Requirements

- `bash`, `curl`, `git`, `gettext` (for `envsubst`)
- Go toolchain (xcaddy invokes it to compile the Caddy binary)
- Docker + buildx (only for the `docker` target)

`yq`, `nfpm`, and `xcaddy` are bootstrapped automatically into `./tools/`
from their GitHub release tarballs, verified against the SHA256 pins in
[lib/tools.sh](lib/tools.sh).

## Layout

```
build.sh entry point for building artifacts
release.sh entry point for publishing — dispatches on provider
check-updates.sh detects pin drift for Caddy, xcaddy, plugins, tools, dist files
build.yaml configuration
lib/
  common.sh shared helpers (cfg/yq, pkg_version, tool bootstrap)
  tools.sh pinned versions + SHA256 for yq, nfpm
  build-binary.sh xcaddy invocation
  build-packages.sh  nfpm deb/apk packaging
  build-docker.sh buildx multi-arch image
  release-forgejo.sh forgejo backend (registries + releases)
  release-github.sh  github backend (releases + ghcr.io)
templates/ nfpm + Dockerfile templates (envsubst-rendered)
dist/ static payload synced from upstream Caddy/Alpine repos
tests/ artifact-level smoke tests
```

## License

The build scripts, workflows, tests, templates, and configuration in
this repository are licensed under the [Apache License 2.0](LICENSE).

Files under [dist/](dist/) are synced verbatim from upstream and remain
under their original licenses:

| Path | Upstream | License |
|-|-|-|
| `dist/caddy-dist/` | [caddyserver/dist](https://github.com/caddyserver/dist) | Apache-2.0 |
| `dist/aports/` | [alpinelinux/aports](https://github.com/alpinelinux/aports) (`community/caddy`) | MIT (per the aports repository) |

Caddy itself is built from
[caddyserver/caddy](https://github.com/caddyserver/caddy) (Apache-2.0)
via xcaddy; the resulting binary is redistributed under that license.
Plugin licenses depend on each module in `xcaddy.plugins` — check the
respective project for terms.
