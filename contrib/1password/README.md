# Optional: run the web relay with logins from 1Password

Not part of OpenIPTV itself; the apps take logins directly. If you keep your
logins in 1Password and run the self-hosted web relay, this starts it with
values read from 1Password at launch (kept only in the process's memory):

```sh
contrib/1password/serve.sh --emby "Emby Connect" --xtream "My IPTV" [--lan]
```
