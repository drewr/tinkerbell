FROM alpine:3.22
RUN apk add --no-cache qemu-system-x86_64 qemu-img ovmf iproute2 socat
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
