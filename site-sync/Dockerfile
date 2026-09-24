FROM alpine:3.22

RUN apk add --no-cache git rsync ca-certificates tini

COPY sync.sh /usr/local/bin/sync.sh
RUN chmod +x /usr/local/bin/sync.sh

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/local/bin/sync.sh"]
