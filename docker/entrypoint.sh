#!/bin/bash
# Pelican-style entrypoint: register the running uid, expand {{VAR}} in $STARTUP and exec it.
cd /home/container || exit 1

# Wings starts the container as the node's uid/gid. /etc/passwd and /etc/group are symlinks into /tmp;
# with system.passwd.enable Wings mounts its own files there (read-only), otherwise they are written here
uid=$(id -u) gid=$(id -g)
if ! getent passwd "$uid" >/dev/null 2>&1; then
  { cat /etc/passwd.image; grep -q "^[^:]*:[^:]*:$uid:" /etc/passwd.image || echo "container:x:$uid:$gid::/home/container:/bin/bash"; } >/tmp/passwd 2>/dev/null
fi
if ! getent group "$gid" >/dev/null 2>&1; then
  { cat /etc/group.image; grep -q "^[^:]*:[^:]*:$gid:" /etc/group.image || echo "container:x:$gid:"; } >/tmp/group 2>/dev/null
fi

INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
export INTERNAL_IP

STARTUP="${STARTUP:-/usr/local/bin/fs25-pelican}"
MODIFIED_STARTUP=$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')

echo "container@pelican~ ${MODIFIED_STARTUP}"
eval "exec ${MODIFIED_STARTUP}"
