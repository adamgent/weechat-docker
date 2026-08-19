# weechat-docker

[WeeChat](https://weechat.org/) running in a container, with an SSH server in front of it.
You `ssh` into the container and land directly inside the running WeeChat, which lives in a
detached `tmux` session — so the client keeps running (and stays connected to IRC) whether or
not anyone is logged in.

Built on the official [`weechat/weechat`](https://github.com/weechat/weechat-container) image.

```
ssh -p 2222 weechat@yourhost
        │
        └── sshd (key-only auth) ──> login shell = weechat-shell ──> tmux attach ──> weechat
                                                                        ▲
                        started at container boot by the entrypoint ────┘
```

## Quick start

```bash
mkdir -p keys && cp ~/.ssh/id_ed25519.pub keys/
```

```bash
docker compose up -d --build
```

```bash
ssh -p 2222 weechat@localhost
```

That last command drops you straight into WeeChat. Detach with **Ctrl-a d** (the tmux prefix is
remapped to `Ctrl-a` so it stays out of WeeChat's way) or just close the connection — WeeChat
keeps running.

## How you get in

Public-key authentication only; passwords and root login are disabled. Keys are collected at
startup from any of these, all optional and additive:

| Source | Notes |
| --- | --- |
| `./keys/*.pub`, `./keys/authorized_keys` | mounted read-only at `/keys`; copied into place with correct ownership |
| `SSH_AUTHORIZED_KEYS` env var | one or more keys, newline separated |
| `SSH_AUTHORIZED_KEYS_FILE` env var | path to a file, e.g. a Docker secret |

If no keys are found the entrypoint logs a warning and nobody can log in.

SSH host keys are generated on first boot into the `ssh-host-keys` volume, so the host
fingerprint survives image rebuilds and you don't get "REMOTE HOST IDENTIFICATION HAS CHANGED"
every time you update.

## Day-to-day

```bash
docker compose logs -f weechat
```

Get a plain root shell for maintenance (SSH always lands in WeeChat by design):

```bash
docker exec -it weechat bash
```

Non-interactive SSH commands still work, which is handy for scripting:

```bash
ssh -p 2222 weechat@localhost 'tmux capture-pane -p -t weechat | tail -20'
```

Restart WeeChat without restarting the container:

```bash
docker exec -u weechat weechat tmux kill-session -t weechat
```

The next SSH login recreates the session (`tmux new-session -A`), so this is safe — but see
"Persistence" first: your IRC connections drop.

## Persistence

| Path | Volume | Contents |
| --- | --- | --- |
| `/home/weechat/.config/weechat` | `weechat-config` | `weechat.conf`, `irc.conf`, `sec.conf`, … |
| `/home/weechat/.local/share/weechat` | `weechat-data` | logs, scripts, xfer downloads |
| `/etc/ssh/keys` | `ssh-host-keys` | SSH host keys |

On `docker stop`, the entrypoint sends `/quit` to WeeChat and waits (up to
`WEECHAT_QUIT_TIMEOUT`, default 15s) so configuration is written out cleanly, then stops sshd.
`stop_grace_period: 30s` in the compose file gives it room to finish.

Store your IRC passwords in WeeChat's [secured data](https://weechat.org/files/doc/weechat/stable/weechat_user.en.html#secured_data)
(`/secure passphrase`, `/secure set`) rather than plaintext in `irc.conf`.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `SSH_AUTHORIZED_KEYS` | — | public keys, newline separated |
| `SSH_AUTHORIZED_KEYS_FILE` | — | file containing public keys |
| `SSH_AUTHORIZED_KEYS_DIR` | `/keys` | directory of mounted `*.pub` files |
| `WEECHAT_TMUX_SESSION` | `weechat` | tmux session name |
| `WEECHAT_TMUX_DETACH_OTHERS` | unset | if set, a new login detaches other clients instead of mirroring |
| `WEECHAT_QUIT_TIMEOUT` | `15` | seconds to wait for WeeChat to quit on shutdown |
| `TZ` | `UTC` | container timezone |

Build args:

| Arg | Default | Purpose |
| --- | --- | --- |
| `WEECHAT_IMAGE` | `weechat/weechat:latest` | upstream base image — pin it, e.g. `weechat/weechat:4.10.0-debian` |
| `WEECHAT_USER` | `weechat` | login/account name (uid/gid stay 1000) |

tmux defaults live in [rootfs/etc/tmux.conf](rootfs/etc/tmux.conf): prefix `Ctrl-a`, mouse on,
20k lines of scrollback, status bar off (WeeChat draws its own).

## Security notes

- Key-only auth, `AllowUsers weechat`, `MaxAuthTries 3`, no TCP/agent/X11 forwarding — see
  [rootfs/etc/ssh/sshd_config](rootfs/etc/ssh/sshd_config).
- `sshd` runs as root (it has to, to switch users); WeeChat and your session run as uid 1000.
- Publishing port 22 straight to the internet invites brute-force noise. Prefer binding to
  localhost or a VPN/WireGuard interface, e.g. `"127.0.0.1:2222:22"` or `"10.8.0.1:2222:22"`,
  and reaching it through a tunnel.
- `ClientAliveInterval 60` keeps long-lived sessions from being dropped by NAT timeouts.

## Architecture caveat

The upstream `weechat/weechat` images are published for **linux/amd64 only**, so this image is
amd64 too. On an Apple Silicon or ARM host it runs under emulation (works fine — WeeChat is not
CPU-bound). For a native arm64 image, point `WEECHAT_IMAGE` at an arm64 WeeChat base you build
yourself from [weechat-container](https://github.com/weechat/weechat-container), then add
`linux/arm64` to `PLATFORMS` in the workflow.

## CI

[.github/workflows/build.yml](.github/workflows/build.yml) builds on push/PR to `main`, on
`v*` tags, and weekly (to pick up upstream WeeChat and Debian security updates). Every build
runs [test/smoke-test.sh](test/smoke-test.sh), which boots the image with a throwaway key and
asserts that:

1. the container reaches a healthy state (tmux session alive, `weechat` process running),
2. a non-interactive `ssh` command works,
3. an interactive login lands inside WeeChat under tmux,
4. password authentication is refused,
5. `docker stop` quits WeeChat gracefully.

Non-PR builds push to `ghcr.io/<owner>/<repo>`. Then use it directly:

```bash
docker run -d --name weechat -p 2222:22 -e SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" ghcr.io/OWNER/weechat-docker:latest
```

Run the smoke test locally against your own build:

```bash
./test/smoke-test.sh weechat-ssh:test
```
