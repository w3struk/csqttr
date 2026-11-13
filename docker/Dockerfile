FROM alpine:3.21

# Runtime dependencies only; the server binary is a static musl build.
# openssl generates the self-signed TLS pair on first start, curl is kept for
# diagnostics inside the container.
RUN apk add --no-cache ca-certificates curl iproute2 iptables openssl

# The binary is placed in the build context by CI (release asset
# csqtt-linux-amd64). It is not built inside this image.
COPY csqtt /usr/local/bin/csqtt
COPY entrypoint.sh healthcheck.sh /usr/local/lib/csqtt/
RUN chmod 0755 /usr/local/bin/csqtt \
    /usr/local/lib/csqtt/entrypoint.sh \
    /usr/local/lib/csqtt/healthcheck.sh

# First start provisions /etc/csqtt; the volume keeps it afterwards.
VOLUME ["/etc/csqtt"]

ENTRYPOINT ["/usr/local/lib/csqtt/entrypoint.sh"]
