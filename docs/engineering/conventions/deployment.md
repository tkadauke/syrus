# Deployment

Use these rules for the single-host Docker distribution and image lifecycle.

- **Single-host Docker distribution** — `install.sh --docker` pulls
  `ghcr.io/tkadauke/syrus-backend` and starts the Compose stack; `bin/compose-up`
  builds the same stack locally. Keep `compose.env.example`, `.env.example`,
  and bootstrap payload expectations in sync when adding required env. Never
  regenerate `.env` over an existing `syrus_syrus-data` volume — those
  Active Record encryption keys must match the persisted DB. Test image-level
  changes with `bin/test-docker`; publish only through `bin/publish-image`,
  which builds, runs that integration gate, then pushes. Docker image scripts
  share common build/login/cache helpers in `bin/docker-image-lib`; extend that
  helper instead of copying Dockerfile target, GHCR login, pushed-manifest
  validation, Docker/GHCR plumbing, or registry cache logic between
  `bin/deploy`, `bin/publish-image`, and `bin/compose-up`.
  `SYRUS_DOCKER_REGISTRY_CACHE=1` opts local compose/publish builds into the
  registry BuildKit cache, and `SYRUS_DOCKER_CACHE_REF` overrides the cache tag.
  `bin/deploy` prunes the previous deploy's SHA tags **before** building as
  well as after, and runs `syrus_docker_require_free_space` as a preflight
  (`SYRUS_DOCKER_MIN_BUILD_FREE_GB`, default 20, matching
  `SYRUS_DOCKER_POST_BUILD_MIN_FREE_SPACE`'s target). Both exist because the
  post-build prune only runs after every build, push and verify succeeds: a
  deploy that dies partway leaves its own ~16GB worker-dev image and the
  previous deploy's behind, two failures fill a 100GB Colima volume, and the
  next deploy dies on ENOSPC extracting a layer inside the native-toolchain
  smoke check — running out of disk prevents the cleanup that would free the
  disk. Free space is measured inside the daemon (`DockerRootDir`), not on the
  host, because on Colima/Lima or any remote context the host's free space is
  unrelated; a preflight that cannot measure reports and continues rather than
  blocking a deploy.
  For desktop-app iteration against unpublished backend changes, `bin/build-local-image`
  builds `syrus-backend:dev-<sha>` from the working tree; stage it into the DMG
  with `SYRUS_BACKEND_IMAGE=<ref> npm --prefix desktop run build`. The
  registry is selected by data, not code: manifest.json carries the
  fully-qualified ref, install.sh pulls it verbatim, release builds pin
  `ghcr.io/tkadauke/...`. Local-only tags survive only until Docker is wiped;
  for wipe-everything install testing use `GHCR_USER=<you> bin/build-local-image
  --push`, which pushes `ghcr.io/<you>/syrus-backend:dev-<sha>` to the fork's
  GHCR (needs `write:packages` in `GHCR_TOKEN` or `~/.config/syrus/ghcr-token`;
  make that package public once so installs need no docker login). Never
  stage a published ref you don't control — a successful pull would clobber
  what you meant to test. install.sh classifies pull failures: exit 30
  network/other, 31 access denied, 32 tag not found.
