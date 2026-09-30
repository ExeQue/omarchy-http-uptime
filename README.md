# HTTP Uptime

An Omarchy bar widget that monitors your URLs: 2xx responses, valid SSL certificates, response times and uptime over the last 24 hours, 7 days and 30 days.

![HTTP Uptime panel](preview.png)

## Features

- **Status at a glance.** The bar icon turns red when a URL is down or has an SSL error, yellow when a URL is slow or its certificate expires soon, The status colours are fixed, so they look the same in every theme. Hover it for a summary of every URL.
- **Checks.** A URL is up when it answers with a 2xx status (redirects are followed) and a valid certificate: chain, hostname and expiry are all verified. Requests time out after 10 seconds.
- **Slow responses.** Set a response-time limit globally or per URL.
- **Certificate expiry warnings** a configurable number of days ahead.
- **Notifications** when a URL gets worse than its previous check (down, SSL error, slow, certificate expiring) and when it recovers. Clicking a notification opens that URL's details.
- **Panel** grouped by severity: down first, then slow, then healthy. It shows when the current outage or slow streak began.
- **Detail view** per URL, with uptime and slow-response charts for 3h, 24h, 7d and 30d, and the last 10 checks with status, HTTP code and response time.
- **Custom headers** per URL (up to 10), for example `Authorization`. Values are stored encrypted in the system keyring.
- **Settings in the panel.** Add, edit, reorder (drag and drop) and remove URLs, and set the check interval and slow limit per URL.

## Screenshots

| Panel | Detail view | Settings |
|---|---|---|
| ![Panel grouped by severity](screenshots/panel.png) | ![Detail view with charts and last checks](screenshots/detail.png) | ![Settings with per-URL interval and slow limit](screenshots/settings.png) |

## Install

```sh
omarchy plugin add https://github.com/ExeQue/omarchy-http-uptime --enable
```

## Uninstall

```sh
omarchy plugin remove exeque.omarchy-http-uptime
```

This removes the plugin and its bar widget. Your settings, history and custom header values are kept in case you reinstall; Omarchy has no uninstall hook to remove them. To delete them too:

```sh
rm -f ~/.config/omarchy/http-uptime.json
rm -rf ~/.local/state/omarchy/http-uptime
secret-tool clear service exeque.omarchy-http-uptime
```

Removing a single URL in settings deletes its history and header values right away.

## Usage

| Action | Result |
|---|---|
| Left-click the icon | Open the panel |
| Right-click the icon | Check every URL now |
| Click a URL in the panel | Open its detail view |
| Gear icon in the panel | Settings: add, edit, reorder and remove URLs |

In settings, a row with unsaved changes shows ✓ (save) and ↺ (revert) in place of the trash icon. Enter in the URL field also saves the row. Unsaved changes are discarded when you leave settings.

## Custom headers

In settings, click the key icon on a row, enter a header name and value, and press **Set**. Setting an existing name replaces its value.

- **Storage.** Values are stored in the Secret Service keyring (gnome-keyring, part of a standard Omarchy install), which is encrypted and unlocked at login. The config file holds only the header names.
- **Visibility.** Values are passed through stdin and a file descriptor (`curl -H @/dev/fd/N`), never on a command line where other processes could read them. They are never shown in the panel after saving.
- **Redirects.** URLs with custom headers do not follow redirects, so headers can't leak to another host. A 3xx response is reported as down with an explanation.
- **Locked keyring.** If a value can't be read, for example because the keyring is locked, the entry turns blue and you get a "Keyring locked" notification. The check is skipped and not recorded in the history, and the bar icon stays neutral because this is usually temporary.
- **Cleanup.** Renaming a URL moves its headers along. Removing a URL deletes its headers from the keyring.
- **Validation.** Names must be valid HTTP header tokens. Values may not contain line breaks and are at most 4096 characters.

## Configuration

Settings are stored in `~/.config/omarchy/http-uptime.json`, which the panel reads and writes. You can also edit the file by hand; changes apply on save.

```json
{
  "interval": 300,
  "warnDays": 14,
  "slowMs": 2000,
  "targets": [
    { "url": "https://example.com/" },
    { "url": "https://api.example.com/health", "interval": 60, "slowMs": 500, "headers": ["Authorization"] }
  ]
}
```

| Key | Meaning |
|---|---|
| `interval` | Default seconds between checks (minimum 30) |
| `warnDays` | Warn when a certificate expires within this many days |
| `slowMs` | Default response time, in milliseconds, above which a URL counts as slow |
| `targets[].interval`, `targets[].slowMs` | Per-URL overrides |
| `targets[].headers` | Names of custom headers; the values are in the keyring |

## Where data is stored

Everything stays on your machine.

| What | Location |
|---|---|
| Settings and monitored URLs | `~/.config/omarchy/http-uptime.json` |
| Custom header values | System keyring (Secret Service), attributes `service=exeque.omarchy-http-uptime`, `url`, `header` |
| Check history | `~/.local/state/omarchy/http-uptime/<url>-<hash>.tsv` (under `$XDG_STATE_HOME` when that is set) |
| Plugin code | `~/.config/omarchy/plugins/exeque.omarchy-http-uptime/` |

Each history file holds one URL, with one line per check: epoch, up (0/1), status, HTTP code and response time in milliseconds. The file name is a readable form of the URL plus a short hash. Lines older than 30 days are pruned. Editing an entry's URL keeps its history. Removing an entry asks for confirmation when it has history, and its file is deleted about 10 minutes later. Delete the directory to reset all history.

## Privacy

- The plugin sends requests only to the URLs you add. It makes an HTTPS request with `curl`, and an `openssl` connection to read certificate expiry.
- There are no services, no background daemons outside the shell, and no privilege escalation.

## Dependencies

`bash`, `curl`, `openssl`, `awk`, `md5sum`, `secret-tool` (libsecret, with gnome-keyring) and `omarchy-notification-send`, all present on a standard Omarchy install.

## Limits

To keep the long-running shell bounded, the plugin enforces:

- at most 50 URLs, each at most 2048 characters (extra or invalid entries in a hand-edited config are ignored);
- at most 6 checks at a time, each with a 10 second request timeout and a 10 second certificate timeout;
- keyring lookups time out after 3 seconds (the check is then skipped) and keyring writes after 30 seconds, so a locked keyring waiting for an unlock prompt can't stall monitoring;
- a check run is stopped after 10 minutes at most, and stuck processes are restarted by a watchdog;
- a check interval of at least 30 seconds;
- at most 256 KB of script output read per run;
- at most 100,000 history records per URL, which covers 30 days at the 30 second minimum interval.

## Notes

- There is one widget per monitor. Only the first widget runs checks and sends notifications, and it shares the results with the others.
- Uptime is the share of checks that were up in each window, so a short outage between two checks can go unnoticed. Use a shorter interval for URLs where that matters.
- Revoked certificates are not detected, because `curl` does not check revocation.

## License

MIT
