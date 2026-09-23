# syntax=docker/dockerfile:1

# The Tailscale plugin's privileged service container: owns tailscaled, its
# persisted state, /dev/net/tun, and NET_ADMIN/NET_RAW -- see
# docs/plans/tailscale-privileged-service-lane.md. Unlike every other
# container-backed plugin image in this repo, this one must run tailscaled as
# root: it needs to create and configure a TUN network interface, which an
# unprivileged user cannot do even with the capability granted to the
# container.

# The Go build runs on the build host and cross-compiles, so a multi-arch
# build never compiles under QEMU emulation.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.25-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /tailscale-service .

FROM docker.io/library/alpine:3.22
RUN apk add --no-cache tailscale ca-certificates \
 && mkdir -p /var/lib/tailscale /var/run/tailscale
COPY --from=build /tailscale-service /usr/local/bin/tailscale-service
# tailscaled needs to run as root to create and configure the TUN interface;
# no USER directive here is the deliberate exception to every other
# container-backed plugin image in this repo running unprivileged.
VOLUME ["/var/lib/tailscale"]
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 CMD ["/usr/local/bin/tailscale-service", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/tailscale-service"]
