# Overseer CLI

<p align="center">
  <img src="assets/icon.jpg" alt="Overseer icon" width="240" />
</p>

Overseer is a macOS process monitor you run from the command line.

## Why use it?

Apps and AI agents can leak memory, especially in long-running browser-based sessions.

Overseer does not fix bad apps; it is a convenience failsafe for people who keep killing runaway processes manually.

Set CPU, memory, and runtime limits to auto-notify or kill before your machine slows down.

## Video

```text
Demo video coming soon.
```

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

Example covering all supported metrics and actions:

```json
{
  "poll_interval_seconds": 5,
  "only_tree_roots": true,
  "warning_threshold": 0,
  "notify_on_kill": true,
  "rules": [
    {
      "process": "ai_agent",
      "metric": "cpu_percent",
      "threshold": 90,
      "for_seconds": 10,
      "action": "notify"
    },
    {
      "process": "my_terminal",
      "metric": "memory_mb",
      "threshold": 4096,
      "for_seconds": 30,
      "action": "kill",
      "signal": "term"
    },
    {
      "process": "chrome_headless",
      "metric": "runtime_seconds",
      "threshold": 7200,
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
