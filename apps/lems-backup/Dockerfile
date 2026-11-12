FROM alpine:3.20
# sqlite CLI 提供 .backup（原生在线备份 API）；openssh-client 走异地 scp；
# tini 收信号，crond 前台跑
RUN apk add --no-cache sqlite openssh-client tini
COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/sbin/tini","--","/usr/local/bin/entrypoint.sh"]
