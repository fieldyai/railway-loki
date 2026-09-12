# Stage 1: Get the Loki binary from the official image
# Pinned: `latest` rebuilt the image onto whatever Loki shipped that day.
FROM grafana/loki:3.7.7 AS loki

# Stage 2: Alpine base with shell, nginx, and Loki
FROM alpine:latest

RUN apk add --no-cache nginx gettext bash

# Copy Loki binary from official image
COPY --from=loki /usr/bin/loki /usr/bin/loki

# Copy configs
COPY loki-config.yaml /etc/loki/loki-config.yaml
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Railway provides $PORT — nginx listens there, proxies to Loki on 3100
EXPOSE 3100

ENTRYPOINT ["/entrypoint.sh"]
