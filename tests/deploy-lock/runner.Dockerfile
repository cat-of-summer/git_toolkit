FROM alpine:3.22

RUN apk add --no-cache bash coreutils util-linux openssh-client sshpass lftp
