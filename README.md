# Dose

A small macOS menu bar monitor for Codex usage. The ring shows your remaining limit; the center shows days or hours until reset.

- Remaining quota, reset date, and top chats by token usage over 24 hours or 7 days.
- Available usage-limit resets and expiry details, when Codex provides them.
- Optional launch at login, under the gear button.

Requires macOS 13+, Apple Command Line Tools, and a local Codex installation.

```sh
./build.sh
open dist/Dose.app
```

Local logs refresh every 15 seconds. Reset credits are displayed only; Dose does not redeem them.

```sh
./test.sh
```

## Privacy

Dose processes session logs, chat titles, and token usage locally on your Mac and does not upload them. It has no analytics or telemetry, stores no credentials, and makes no automatic network requests. **Refresh through Codex** manually fetches account limits and available resets using Codex's existing sign-in, without sending local session data or token statistics.

## Limitations

- Chat rankings only cover logs on this Mac. Other-device and cloud sessions are missing unless their logs are available locally.
- Quota is account-wide, but local snapshots can be stale. Use **Refresh through Codex** for current limits.
- Token counts do not translate directly into quota percentages.
