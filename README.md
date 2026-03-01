# Overseer CLI

Overseer is a macOS process monitor you run from the command line.

## Requirements

- macOS 13+
- Xcode Command Line Tools (Swift)

## Build

```bash
swift build
```

Run directly from source:

```bash
swift run overseer help
```

Build a release binary:

```bash
swift build -c release
./.build/release/overseer version
```

## Development with mise

Install/pin tools from `mise.toml`:

```bash
mise install
```

Common commands:

```bash
mise run build
mise run build-release
mise run run
mise run overseer -- version
mise run release-check
mise run release-snapshot
```

## Install

With the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/oomathias/overseer/main/install | bash
```

Script options:

- `OVERSEER_VERSION=latest|vX.Y.Z` (default: `latest`)
- `OVERSEER_INSTALL_DIR=/absolute/path` (default: `/usr/local/bin`)
- `OVERSEER_REQUIRE_SIGNATURE=auto|0|1` (default: `auto`)

The script installs a prebuilt binary for your macOS architecture and verifies checksums. If `cosign` is available (or `OVERSEER_REQUIRE_SIGNATURE=1`), it also verifies Sigstore bundles for the archive and checksums.

Manual install from source:

```bash
swift build -c release
install -m 755 ./.build/release/overseer /usr/local/bin/overseer
overseer version
```

## Config

Default config path:

```text
~/.config/overseer/config.json
```

Minimal example:

```json
{
  "poll_interval_seconds": 5,
  "only_tree_roots": true,
  "warning_threshold": 0,
  "notify_on_kill": true,
  "rules": [
    {
      "process": "SomeProcess",
      "metric": "cpu_percent",
      "threshold": 90,
      "for_seconds": 10,
      "action": "notify"
    }
  ]
}
```

## Usage

Show help:

```bash
overseer help
```

Validate config:

```bash
overseer validate --config ~/.config/overseer/config.json
```

Run monitor in foreground:

```bash
overseer monitor --config ~/.config/overseer/config.json --verbose --live
```

Disable live single-tick screen updates:

```bash
overseer monitor --config ~/.config/overseer/config.json --verbose --no-live
```

Compatibility mode (same as monitor):

```bash
overseer --config ~/.config/overseer/config.json --quiet
```

Manage launchd service:

```bash
overseer service install --config ~/.config/overseer/config.json
overseer service status
overseer service restart
overseer service stop
overseer service uninstall
```

## Release

Releases are automated with GoReleaser on Git tags that match `v*`.

- Workflow: `.github/workflows/release.yml`
- Config: `.goreleaser.yaml`
- Artifacts: `overseer_<version>_darwin_arm64.tar.gz`, `overseer_<version>_darwin_amd64.tar.gz`
- Signatures: Sigstore bundles for each archive plus `checksums.txt.sigstore.json`

For Apple code-sign + notarization (same model as `snav`), configure these GitHub Actions repository secrets:

- `MACOS_SIGN_P12`
- `MACOS_SIGN_PASSWORD`
- `MACOS_NOTARY_KEY`
- `MACOS_NOTARY_KEY_ID`
- `MACOS_NOTARY_ISSUER_ID`

Local dry run:

```bash
goreleaser release --snapshot --clean --skip=publish,sign
```

## Notes

- Press `Ctrl+C` to stop foreground monitoring.
- For persistent/background monitoring, prefer `overseer service install`.
- In an ANSI-capable interactive terminal, `--verbose --live` uses a colorized view and keeps only the current tick on screen.
