# syntax=docker/dockerfile:1
# eh-os D-158 (eh-os#1236): acme-dns, the DNS server an installation with public certificates runs
# for the console's DNS-01 challenge. Its project publishes an image for amd64 alone, and EHOS's
# servers are arm64, so this builds its release for both: the source at the commit of the tag
# `v2.0.2`, cross-compiled on the builder's own platform with no cgo (its SQLite driver is Go), so
# no step runs under emulation. Every base image is pinned by the digest of its index.
# `.github/workflows/acme-dns.yml` builds and publishes it; the installer pins what it published.
ARG ACME_DNS_COMMIT=4e5a69e5fb742dde4f755b7f56aee2aea76e19bf

# Go 1.25.x on Alpine, by the digest of its index of 5 November 2026.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine@sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59 AS build
ARG ACME_DNS_COMMIT
ARG TARGETOS
ARG TARGETARCH
ADD https://github.com/acme-dns/acme-dns.git#${ACME_DNS_COMMIT} /src
WORKDIR /src
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/acme-dns .

# Alpine, not a base with no shell: the installer registers acme-dns's one account through the
# pod's own loopback, with BusyBox's wget, so the API is reached from no other address for it.
# Alpine 3.22, by the digest of its index of 5 November 2026.
FROM alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
ARG ACME_DNS_COMMIT
LABEL org.opencontainers.image.source="https://github.com/EmpoweredHouse/ehos-tools" \
      org.opencontainers.image.title="acme-dns" \
      org.opencontainers.image.description="acme-dns v2.0.2, built for amd64 and arm64 for EHOS" \
      org.opencontainers.image.version="v2.0.2" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.revision="${ACME_DNS_COMMIT}"
COPY --from=build /out/acme-dns /usr/local/bin/acme-dns
# A user that is not root; the pod's security context says the same.
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/acme-dns"]
CMD ["-c", "/etc/acme-dns/config.cfg"]
