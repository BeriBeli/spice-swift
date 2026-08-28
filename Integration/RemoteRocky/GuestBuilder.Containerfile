FROM docker.io/library/alpine:3.22

# Keep the guest compiler and publication lock tooling out of the QEMU runtime
# image. Exact package versions make the builder contract independently
# auditable while build-guest.sh continues to pin every guest package.
RUN apk add --no-cache \
        build-base=0.5-r3 \
        ca-certificates \
        cpio \
        flock=2.41-r9 \
        fortify-headers=1.1-r5 \
        gzip \
        libxi-dev=1.8.2-r0

WORKDIR /work

CMD ["/work/build-guest.sh"]
