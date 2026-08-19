# syntax=docker/dockerfile:1

# Upstream image from https://github.com/weechat/weechat-container
# Override to pin a version, e.g. --build-arg WEECHAT_IMAGE=weechat/weechat:4.10.0-debian
ARG WEECHAT_IMAGE=weechat/weechat:latest

FROM ${WEECHAT_IMAGE}

# Upstream runs as the unprivileged "user" (uid 1000); we need root to add sshd.
USER root

# Rename user/group 1000 -> weechat so you can "ssh weechat@host".
# uid/gid stay 1000 so existing volumes keep working.
ARG WEECHAT_USER=weechat
ENV WEECHAT_USER=${WEECHAT_USER} \
    HOME=/home/${WEECHAT_USER} \
    LANG=C.UTF-8 \
    TERM=xterm-256color

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server \
        tmux \
        tini \
    ; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    groupmod -n "${WEECHAT_USER}" user; \
    usermod  -l "${WEECHAT_USER}" -d "/home/${WEECHAT_USER}" -m user; \
    # no password (but NOT "locked": sshd refuses locked accounts without PAM)
    usermod -p '*' "${WEECHAT_USER}"; \
    usermod -p '*' root; \
    mkdir -p /etc/ssh/keys /etc/ssh/authorized_keys.d /run/sshd \
             "/home/${WEECHAT_USER}/.ssh" \
             "/home/${WEECHAT_USER}/.config/weechat" \
             "/home/${WEECHAT_USER}/.local/share/weechat" \
             "/home/${WEECHAT_USER}/.cache/weechat"; \
    chmod 700 "/home/${WEECHAT_USER}/.ssh"; \
    chown -R "${WEECHAT_USER}:${WEECHAT_USER}" "/home/${WEECHAT_USER}"; \
    rm -f /etc/ssh/ssh_host_*

COPY rootfs/ /

RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/weechat-shell /usr/local/bin/weechat-attach; \
    usermod -s /usr/local/bin/weechat-shell "${WEECHAT_USER}"; \
    chmod 0644 /etc/ssh/sshd_config /etc/tmux.conf; \
    echo /usr/local/bin/weechat-shell >> /etc/shells; \
    /usr/sbin/sshd -t -f /etc/ssh/sshd_config -o 'HostKey /dev/null' 2>/dev/null || true

VOLUME ["/home/weechat/.config/weechat", "/home/weechat/.local/share/weechat", "/etc/ssh/keys"]

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD /usr/local/bin/entrypoint.sh healthcheck

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["sshd"]
