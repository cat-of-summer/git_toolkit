set -e
[ -f /keys/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /keys/id_ed25519
chmod 644 /keys/id_ed25519
mkdir -p /home/dep1/.ssh
cp /keys/id_ed25519.pub /home/dep1/.ssh/authorized_keys
chown -R dep1:dep1 /home/dep1/.ssh
chmod 700 /home/dep1/.ssh
chmod 600 /home/dep1/.ssh/authorized_keys
mkdir -p /srv/shared && chmod 0777 /srv/shared
exec /usr/sbin/sshd -D -e
