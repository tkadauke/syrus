# syntax=docker/dockerfile:1

# The plugin runtime manager: the one container in a Compose install of Syrus
# that is given the Docker socket. It is built small and static on purpose --
# the less there is in it, the less there is to trust.

FROM docker.io/library/golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /runtime-manager .

# distroless/static: no shell, no package manager, no curl. It runs as root so
# it can open the Docker socket, which is root-owned on the host; the container
# gets no capabilities beyond the default and holds nothing else.
FROM gcr.io/distroless/static-debian12
COPY --from=build /runtime-manager /runtime-manager
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 CMD ["/runtime-manager", "healthcheck"]
ENTRYPOINT ["/runtime-manager"]
