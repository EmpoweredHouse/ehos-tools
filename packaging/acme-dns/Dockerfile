# syntax=docker/dockerfile:1.24@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
# eh-os D-158 (eh-os#1236): acme-dns, the DNS server an installation with public certificates runs
# for the console's DNS-01 challenge. Its project publishes an image for amd64 alone, and EHOS's
# servers are arm64, so this builds its release for both: the source at the commit of the tag
# `v2.0.2`, cross-compiled on the builder's own platform with no cgo (its SQLite driver is Go), so
# no step runs under emulation. The frontend above and every base image are pinned by the digest
# of their index. `.github/workflows/acme-dns.yml` builds and publishes it, for `ehos_platform`'s
# installer to pin by digest.
#
# The commit of acme-dns's tag; the workflow's `VERSION` names the tag, and gives it to the labels.
ARG ACME_DNS_COMMIT=4e5a69e5fb742dde4f755b7f56aee2aea76e19bf
ARG ACME_DNS_VERSION=v2.0.2

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
ARG ACME_DNS_VERSION
LABEL org.opencontainers.image.source="https://github.com/EmpoweredHouse/ehos-tools" \
      org.opencontainers.image.title="acme-dns" \
      org.opencontainers.image.description="acme-dns ${ACME_DNS_VERSION}, built for amd64 and arm64 for EHOS" \
      org.opencontainers.image.version="${ACME_DNS_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.revision="${ACME_DNS_COMMIT}"
COPY --from=build /out/acme-dns /usr/local/bin/acme-dns
# A user that is not root; the pod's security context says the same.
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/acme-dns"]
CMD ["-c", "/etc/acme-dns/config.cfg"]
