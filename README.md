<p align="center">
  <img src="assets/icon.jpg" alt="Overseer icon" width="240" />
</p>

<p align="center"><strong>Overseer</strong></p>

<p align="center"><em>Overseer is a macOS process monitor you run as a daemon or TUI</em></p>

## But why?

Today's apps and AI agents often leak memory, leave child processes behind, or get stuck in high-CPU loops.

Overseer does not fix bad apps. It is a convenience failsafe for people who keep killing runaway processes manually.

Set CPU, memory, and runtime limits to notify or kill processes before your machine slows down.

https://github.com/user-attachments/assets/45c6b1ce-6ddb-4f92-96c2-fd662ec62ab2

## Install

Install the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/oomathias/overseer/main/install | bash
overseer version
```

Install a specific release:

```bash
curl -fsSL https://raw.githubusercontent.com/oomathias/overseer/main/install | OVERSEER_VERSION=vX.Y.Z bash
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

Example config covering all supported metrics and actions:

```json
{
  "poll_interval_seconds": 5,
  "only_tree_roots": true,
  "warning_threshold": 90,
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
    },
    {
      "process": "",
      "pid_file_glob": "~/BrowserService/*.pid",
      "metric": "memory_mb",
      "threshold": 512,
      "for_seconds": 20,
      "action": "notify"
    }
  ]
}
```

### Rule options

Each item in `rules` supports these fields:

- `process` (optional, default: `null`): executable basename to match exactly.
- `pid_file_glob` (optional, default: not set): glob pattern for PID files. When set, the rule applies only to PIDs from matching files that were updated no earlier than the process start time.
- `metric` (required): one of `cpu_percent`, `memory_mb`, or `runtime_seconds`.
- `threshold` (required): numeric threshold for the selected metric.
- `for_seconds` (optional, default: `0`): action fires only after this duration remains above threshold.
- `action` (required): `notify` or `kill`.
- `signal` (optional, default: `term`): `term`, `kill`, or `int`. Used only with `kill`.
- `cooldown_seconds` (optional, default: `60` for `notify`, `0` for `kill`): minimum seconds between repeated actions.

## Global options

Global options live at the top level of the config and apply to all rules:

- `poll_interval_seconds` (default: `5`): poll interval in seconds.
- `only_tree_roots` (default: `true`): if `true`, evaluate only tree-root processes for each rule.
- `warning_threshold` (default: `0`): warn when a metric reaches this percentage of the threshold (e.g. `90` for 90%).
- `notify_on_kill` (default: `true`): if `true`, show a notification for kill actions.

## Usage

Validate config:

```bash
overseer validate --config ~/.config/overseer/config.json
```

Run monitor in the foreground:

```bash
overseer monitor --config ~/.config/overseer/config.json
```

Update the current binary in place:

```bash
overseer update
```

Manage the launchd service:

```bash
overseer service install --config ~/.config/overseer/config.json
overseer service status
overseer service restart
overseer service stop
overseer service uninstall
```

## Notes

- Press `Ctrl+C` to stop foreground monitoring.
- For persistent background monitoring, prefer `overseer service install`.
