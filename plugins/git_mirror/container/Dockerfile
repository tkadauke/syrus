# syntax=docker/dockerfile:1

# The git mirror service behind the git_mirror plugin. It needs a real git
# binary, so unlike the runtime manager it cannot be distroless; it is kept to
# Alpine plus git, and runs as an unprivileged user.

FROM docker.io/library/golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /git-mirror .

FROM docker.io/library/alpine:3.22
RUN apk add --no-cache git ca-certificates \
 && adduser -D -u 1000 mirror \
 && mkdir -p /data \
 && chown mirror:mirror /data
COPY --from=build /git-mirror /usr/local/bin/git-mirror
USER mirror
# A new named volume takes this directory's ownership on first mount, so the
# unprivileged user can write to it.
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 CMD ["/usr/local/bin/git-mirror", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/git-mirror"]
