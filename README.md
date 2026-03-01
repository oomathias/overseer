# Overseer CLI

Overseer is a macOS process monitor you run from the command line.

## Requirements

- macOS 13+
- Xcode Command Line Tools (Swift)

## Install

Install latest:

```bash
curl -fsSL https://raw.githubusercontent.com/oomathias/overseer/main/install | bash
overseer version
```

Install a specific release:

```bash
curl -fsSL https://raw.githubusercontent.com/oomathias/overseer/main/install | OVERSEER_VERSION=v0.2.0 bash
```

Install to a custom path:

```bash
curl -fsSL https://raw.githubusercontent.com/oomathias/overseer/main/install | OVERSEER_INSTALL_DIR="$HOME/.local/bin" bash
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

Disable live single-tick updates:

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

## Notes

- Press `Ctrl+C` to stop foreground monitoring.
- For persistent/background monitoring, prefer `overseer service install`.
