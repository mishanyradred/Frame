FROM redis:7-alpine

COPY redis.conf /usr/local/etc/redis/redis.conf

EXPOSE 6379
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
    CMD redis-cli ping | grep -q PONG || exit 1

CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]
