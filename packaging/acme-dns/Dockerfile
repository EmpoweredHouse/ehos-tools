# syntax=docker/dockerfile:1.24@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
# eh-os D-158 (eh-os#1236): acme-dns, the DNS server an installation with public certificates runs
# for the console's DNS-01 challenge. Its project publishes an image for amd64 alone, and EHOS's
# servers are arm64, so this builds its release for both: the source at the commit of the tag
# `v2.0.2`, with the x/ modules raised below, cross-compiled on the builder's own platform with
# no cgo (its SQLite driver is Go), so no step runs under emulation. The frontend above and every
# base image are pinned by the digest of their index. `.github/workflows/acme-dns.yml` builds and
# publishes it, for `ehos_platform`'s installer to pin by digest.
#
# The commit of acme-dns's tag, and the tag, which the labels and the workflow's image tags carry.
# Renovate moves both together (T-24).
ARG ACME_DNS_COMMIT=4e5a69e5fb742dde4f755b7f56aee2aea76e19bf
ARG ACME_DNS_VERSION=v2.0.2
# The golang.org/x/net the build raises acme-dns's modules to (below), named once for the build
# and the labels.
ARG X_NET_VERSION=v0.62.0

# Go 1.27.3 on Alpine, by the digest of its index of 5 November 2026: the standard library of
# an older Go has advisories that 1.27.3 fixes.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS build
ARG ACME_DNS_COMMIT
ARG X_NET_VERSION
ADD https://github.com/acme-dns/acme-dns.git#${ACME_DNS_COMMIT} /src
WORKDIR /src
# v2.0.2 pins golang.org/x/crypto, x/net and x/text at versions with HIGH advisories, which its
# DNS and HTTP servers use. x/net is raised to `X_NET_VERSION`, which fixes its own (v0.62.0
# fixes CVE-2026-78661, which v0.60.0 has), and its go.mod raises x/crypto, x/text and the other
# x/ modules past theirs. x/net is named by version and the go.mod files it brings are fixed, so
# the build stays the same, and Go checks what it downloads against the checksum database. Done
# before the target is named, so both architectures share the step. Remove this when a release
# of acme-dns has them.
RUN go get golang.org/x/net@${X_NET_VERSION} && go mod tidy
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/acme-dns .

# Alpine, not a base with no shell: the installer registers acme-dns's one account through the
# pod's own loopback, with BusyBox's wget, so the API is reached from no other address for it.
# Alpine 3.22, by the digest of its index of 5 November 2026.
FROM alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
ARG ACME_DNS_COMMIT
ARG ACME_DNS_VERSION
ARG X_NET_VERSION
LABEL org.opencontainers.image.source="https://github.com/EmpoweredHouse/ehos-tools" \
      org.opencontainers.image.title="acme-dns" \
      org.opencontainers.image.description="acme-dns ${ACME_DNS_VERSION}, x/net ${X_NET_VERSION}, amd64 and arm64, for EHOS" \
      org.opencontainers.image.version="${ACME_DNS_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.revision="${ACME_DNS_COMMIT}"
COPY --from=build /out/acme-dns /usr/local/bin/acme-dns
# A user that is not root; the pod's security context says the same.
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/acme-dns"]
CMD ["-c", "/etc/acme-dns/config.cfg"]
