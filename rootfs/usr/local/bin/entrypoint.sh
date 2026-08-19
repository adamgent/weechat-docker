#!/bin/bash
# PID 1 for the weechat-over-ssh container.
#
#   1. make sure persistent ssh host keys exist
#   2. assemble authorized_keys from env vars / mounted files
#   3. start weechat inside a detached tmux session (survives ssh logouts)
#   4. run sshd in the foreground; ssh logins attach to that tmux session
set -euo pipefail

WEECHAT_USER="${WEECHAT_USER:-weechat}"
WEECHAT_HOME="$(getent passwd "$WEECHAT_USER" | cut -d: -f6)"
TMUX_SESSION="${WEECHAT_TMUX_SESSION:-weechat}"
KEY_DIR=/etc/ssh/keys
AUTH_KEYS=/etc/ssh/authorized_keys.d/"$WEECHAT_USER"
KEYS_MOUNT="${SSH_AUTHORIZED_KEYS_DIR:-/keys}"
QUIT_TIMEOUT="${WEECHAT_QUIT_TIMEOUT:-15}"
ENV_FILE=/etc/weechat-container.env

log() { printf '[entrypoint] %s\n' "$*" >&2; }

as_weechat() { runuser -u "$WEECHAT_USER" -- "$@"; }

# ---------------------------------------------------------------- healthcheck
if [ "${1:-}" = "healthcheck" ]; then
    as_weechat tmux has-session -t "$TMUX_SESSION" >/dev/null 2>&1 || {
        echo "tmux session '$TMUX_SESSION' is not running"; exit 1; }
    pgrep -u "$WEECHAT_USER" -x weechat >/dev/null || {
        echo "weechat is not running"; exit 1; }
    exit 0
fi

# ssh sessions do not inherit the container environment, so record the settings
# the login shell needs in a file both sides read.
if [ "${1:-}" != "healthcheck" ]; then
    printf 'WEECHAT_TMUX_SESSION=%s\n' "$TMUX_SESSION" > "$ENV_FILE"
    chmod 644 "$ENV_FILE"
fi

# --------------------------------------------------------------- host keys
mkdir -p "$KEY_DIR" /run/sshd /etc/ssh/authorized_keys.d
[ -f "$KEY_DIR/ssh_host_ed25519_key" ] || {
    log "generating ed25519 host key"
    ssh-keygen -q -t ed25519 -N '' -f "$KEY_DIR/ssh_host_ed25519_key"
}
[ -f "$KEY_DIR/ssh_host_rsa_key" ] || {
    log "generating rsa host key"
    ssh-keygen -q -t rsa -b 4096 -N '' -f "$KEY_DIR/ssh_host_rsa_key"
}
chown root:root "$KEY_DIR"/ssh_host_*
chmod 600 "$KEY_DIR"/ssh_host_*_key
chmod 644 "$KEY_DIR"/ssh_host_*_key.pub

# ---------------------------------------------------- authorized keys
# Sources, all optional and additive:
#   SSH_AUTHORIZED_KEYS       one or more keys, newline separated
#   SSH_AUTHORIZED_KEYS_FILE  path to a file (e.g. a docker secret)
#   /keys/*.pub               read-only mounted directory of public keys
: > "$AUTH_KEYS.tmp"
if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
    printf '%s\n' "$SSH_AUTHORIZED_KEYS" >> "$AUTH_KEYS.tmp"
fi
if [ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ] && [ -r "${SSH_AUTHORIZED_KEYS_FILE}" ]; then
    cat "${SSH_AUTHORIZED_KEYS_FILE}" >> "$AUTH_KEYS.tmp"
fi
if [ -d "$KEYS_MOUNT" ]; then
    # copied (not read in place) so host-side file ownership can't trip StrictModes
    find "$KEYS_MOUNT" -maxdepth 1 -type f \( -name '*.pub' -o -name 'authorized_keys' \) \
        -exec cat {} + >> "$AUTH_KEYS.tmp" 2>/dev/null || true
fi
# de-duplicate, drop blanks/comments
grep -v '^[[:space:]]*\(#\|$\)' "$AUTH_KEYS.tmp" | awk '!seen[$0]++' > "$AUTH_KEYS" || true
rm -f "$AUTH_KEYS.tmp"
chown root:root "$AUTH_KEYS"
chmod 444 "$AUTH_KEYS"

key_count=$(wc -l < "$AUTH_KEYS")
if [ "$key_count" -eq 0 ] && [ ! -s "$WEECHAT_HOME/.ssh/authorized_keys" ]; then
    log "WARNING: no authorized ssh keys found - nobody will be able to log in."
    log "         set SSH_AUTHORIZED_KEYS, or mount public keys into $KEYS_MOUNT"
else
    log "$key_count authorized key(s) loaded for user '$WEECHAT_USER'"
fi

# ---------------------------------------------------------------- home dirs
install -d -o "$WEECHAT_USER" -g "$WEECHAT_USER" -m 700 "$WEECHAT_HOME/.ssh"
for d in .config/weechat .local/share/weechat .cache/weechat; do
    install -d -o "$WEECHAT_USER" -g "$WEECHAT_USER" -m 700 "$WEECHAT_HOME/$d"
done
# volumes created by docker are root-owned on first run
chown "$WEECHAT_USER:$WEECHAT_USER" \
    "$WEECHAT_HOME/.config/weechat" \
    "$WEECHAT_HOME/.local/share/weechat" \
    "$WEECHAT_HOME/.cache/weechat"

# ------------------------------------------------------------ weechat/tmux
if ! as_weechat tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "starting weechat in tmux session '$TMUX_SESSION'"
    as_weechat env TERM=screen-256color \
        tmux -u new-session -d -s "$TMUX_SESSION" -x 200 -y 50 weechat
fi

# ------------------------------------------------------------------- signals
sshd_pid=

shutdown() {
    trap '' TERM INT
    log "shutting down"
    if as_weechat tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log "asking weechat to /quit (saves configuration)"
        as_weechat tmux send-keys -t "$TMUX_SESSION" C-u '/quit' Enter 2>/dev/null || true
        for _ in $(seq 1 "$QUIT_TIMEOUT"); do
            as_weechat tmux has-session -t "$TMUX_SESSION" 2>/dev/null || break
            sleep 1
        done
        as_weechat tmux kill-server 2>/dev/null || true
    fi
    [ -n "$sshd_pid" ] && kill -TERM "$sshd_pid" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

# ---------------------------------------------------------------------- sshd
case "${1:-sshd}" in
    sshd)
        /usr/sbin/sshd -t   # fail fast on a bad config
        log "sshd listening on port 22; ssh $WEECHAT_USER@<host> to attach"
        /usr/sbin/sshd -D -e &
        sshd_pid=$!
        wait "$sshd_pid" || true
        ;;
    *)
        exec "$@"
        ;;
esac
