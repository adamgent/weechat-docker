#!/usr/bin/env bash
# Boots the image, logs in over ssh with a throwaway key, and checks that the
# session lands inside weechat running under tmux.
set -euo pipefail

IMAGE="${1:-weechat-ssh:test}"
NAME="weechat-smoke-$$"
WORKDIR="$(mktemp -d)"
PORT="${PORT:-2299}"

# GNU timeout; not present by default on macOS
run_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"
    fi
}

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> generating throwaway key pair"
ssh-keygen -q -t ed25519 -N '' -C smoke-test -f "$WORKDIR/id"

echo "==> starting container from $IMAGE"
docker run -d --name "$NAME" \
    -p "127.0.0.1:$PORT:22" \
    -e SSH_AUTHORIZED_KEYS="$(cat "$WORKDIR/id.pub")" \
    "$IMAGE" >/dev/null

echo "==> waiting for healthcheck"
for i in $(seq 1 60); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo starting)"
    [ "$status" = "healthy" ] && break
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != "true" ]; then
        echo "container exited:"; docker logs "$NAME"; exit 1
    fi
    sleep 2
done
if [ "$status" != "healthy" ]; then
    echo "container never became healthy (status=$status)"; docker logs "$NAME"; exit 1
fi

SSH_OPTS=(-i "$WORKDIR/id" -p "$PORT"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10)

echo "==> ssh: non-interactive command still works"
out="$(ssh "${SSH_OPTS[@]}" weechat@127.0.0.1 'id -un')"
[ "$out" = "weechat" ] || { echo "expected user weechat, got '$out'"; exit 1; }

echo "==> ssh: interactive login attaches to the weechat tmux session"
# ctrl-a d is the tmux detach binding, so the login exits on its own
login_out="$(printf '\001d' | run_timeout 25 ssh -tt "${SSH_OPTS[@]}" weechat@127.0.0.1 2>&1 || true)"
if ! grep -qi 'weechat' <<<"$login_out"; then
    echo "interactive login did not show weechat:"; echo "$login_out"; exit 1
fi

if ! ssh "${SSH_OPTS[@]}" weechat@127.0.0.1 'tmux list-sessions' | grep -q '^weechat:'; then
    echo "tmux session 'weechat' not found"; exit 1
fi
pane="$(ssh "${SSH_OPTS[@]}" weechat@127.0.0.1 'tmux capture-pane -p -t weechat')"
if ! grep -qi 'weechat' <<<"$pane"; then
    echo "weechat does not appear to be running in the tmux pane:"; echo "$pane"; exit 1
fi

echo "==> ssh: password authentication is refused"
if ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
       -o BatchMode=yes weechat@127.0.0.1 true 2>/dev/null; then
    echo "password auth unexpectedly succeeded"; exit 1
fi

echo "==> graceful shutdown saves configuration"
docker stop -t 30 "$NAME" >/dev/null
docker logs "$NAME" 2>&1 | grep -q 'asking weechat to /quit' || {
    echo "expected graceful weechat shutdown in logs"; docker logs "$NAME"; exit 1; }

echo "PASS"
