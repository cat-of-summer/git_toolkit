FROM alpine:3.22

RUN apk add --no-cache bash coreutils openssh \
 && ssh-keygen -A \
 && adduser -D -s /bin/bash dep1 \
 && adduser -D -s /bin/bash dep2 \
 && echo "dep1:$(head -c 24 /dev/urandom | base64)" | chpasswd \
 && echo 'dep2:pw2' | chpasswd \
 && printf '%s\n' 'PasswordAuthentication yes' 'PermitRootLogin no' 'MaxStartups 100' 'MaxSessions 100' >> /etc/ssh/sshd_config

COPY sshd-entrypoint.sh /usr/local/bin/sshd-entrypoint.sh
ENTRYPOINT ["sh", "/usr/local/bin/sshd-entrypoint.sh"]
