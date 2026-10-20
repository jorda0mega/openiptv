# Rules for agents working in this repository

These rules apply to every agent and tool: Claude, Codex, Grok, Gemini, Cursor, and any task delegated to them.

## Logins and other secrets

Logins have exactly two uses:
1. **The app.** The user types or fills them in on the device. The app stores and logs nothing.
2. **Tests on the developer's Mac.** A script reads them from 1Password at runtime and keeps them in memory.

Nothing else may hold or see a login.

- **Do not send a login to another provider.** That covers other agents, web services and any model's context. Do not print a value, not even in your own command output. Mask it, or print only names and counts.
- **Do not run commands that can print a login.** That includes:
  - the `op` (1Password) command;
  - provider API dumps;
  - channel lists that include the IPTV "Account Info" channels, which spell out the login;
  - Xtream stream URLs, which carry the username and password in the path.
- **Do not write a login anywhere.** That covers code, tests, scripts, config files, `.env` files (even with only `op://` references), commits, commit messages, pull requests, issues, logs and caches.
- **Do not pass a login in an app's launch environment.** The simulator's system log records it. Pass only the address of a local helper that holds it in memory, and fetch it with an ephemeral `URLSession`. The shared session caches responses on disk.
- **Use a pipe, not a here-string.** In zsh, a here-string or heredoc writes its contents to a temporary file.

If a login leaks:
1. Stop.
2. Tell the user at once.
3. Remove every copy you can reach.
4. Say which copies left the machine.

## Tests

- Every bug fix comes with a regression test that fails before the fix.
- Logic checks are Mac tests: `cd apple/MacTests && swift test`, with no simulator. A simulator UI test is only for what needs the drawn app: layout, focus, scrolling, animation, real playback. Run one simulator at a time.
- Most tests run against the test server (`scripts/mock_server.py`).
- The final round before a release runs on the real feeds, with logins handled as above.
