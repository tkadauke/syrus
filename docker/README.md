# Syrus eval image

The eval image is a public, local-only wrapper for `bin/syrus dev`. It is built
for website evaluation flows where someone wants to point Syrus at a checkout on
their machine and get a patch back without installing Ruby or the Claude Code
CLI.

This image is not the production deployment image. Production still uses the
root `Dockerfile` targets for the Rails web and worker pods.

## Run it

```bash
docker run --rm \
  -v "$(pwd)":/work \
  -e ANTHROPIC_API_KEY \
  ghcr.io/tkadauke/syrus:latest dev /work \
  --prompt "Add a CHANGELOG.md with an initial entry."
```

The mounted `/work` directory must be a Git checkout on a branch. Syrus clones
that checkout inside the container, runs the local-dev workflow synchronously,
and writes the resulting diff to stdout unless `--output FILE` is passed.

The image intentionally does not include GitHub cloning, GitHub credentials, or
production database setup. It uses SQLite with an eval-only Rails environment.

## Build locally

```bash
docker build \
  -f docker/Dockerfile.eval \
  --build-arg RUBY_VERSION="$(cat .ruby-version)" \
  -t syrus:eval .
```

Smoke test the entrypoint with a disposable checkout:

```bash
fixture="$(mktemp -d)"
git -C "$fixture" init -q -b main
printf "fixture\n" > "$fixture/README.md"
git -C "$fixture" add README.md
git -C "$fixture" -c user.name=Test -c user.email=test@example.com commit -q -m initial

docker run --rm \
  -v "$fixture":/work \
  -e ANTHROPIC_API_KEY=fake \
  syrus:eval dev /work --prompt "hi"
```

With the fake key, the command should reach Claude Code and fail with an
authentication error rather than a Ruby, Bundler, SQLite, or entrypoint error.

## Publishing

`.github/workflows/build-eval-image.yml` publishes multi-arch `linux/amd64` and
`linux/arm64` images to:

- `ghcr.io/tkadauke/syrus:latest`
- `ghcr.io/tkadauke/syrus:<git-sha>`

GHCR package visibility may need a one-time manual settings change to public
after the first package publish.
