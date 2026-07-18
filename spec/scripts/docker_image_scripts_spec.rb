require "spec_helper"

RSpec.describe "Docker image scripts" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:helper) { File.read(File.join(root, "bin/docker-image-lib")) }
  let(:compose_up) { File.read(File.join(root, "bin/compose-up")) }
  let(:publish_image) { File.read(File.join(root, "bin/publish-image")) }
  let(:deploy) { File.read(File.join(root, "bin/deploy")) }
  let(:test_docker) { File.read(File.join(root, "bin/test-docker")) }
  let(:compose_yml) { File.read(File.join(root, "docker-compose.yml")) }

  it "centralizes Docker build, login, and registry cache helpers" do
    expect(helper).to include("syrus_docker_cache_ref()")
    expect(helper).to include("SYRUS_DOCKER_CACHE_REF")
    expect(helper).to include("syrus_registry_cache_enabled()")
    expect(helper).to include("SYRUS_DOCKER_REGISTRY_CACHE")
    expect(helper).to include("syrus_ghcr_login()")
    expect(helper).to include("syrus_verify_pushed()")
    expect(helper).to include("syrus_docker_build_image()")
    expect(helper).to include("syrus_docker_buildx_image()")
  end

  it "lets local compose builds opt into the shared registry cache" do
    # The base build (with its registry-cache branches) lives in the shared
    # lib now — compose-up calls it and keeps its historical cache-write
    # default; bin/build-local-image reuses the same helper read-only.
    expect(compose_up).to include(". ./bin/docker-image-lib")
    expect(compose_up).to include('SYRUS_DOCKER_CACHE_PUSH="${SYRUS_DOCKER_CACHE_PUSH:-1}"')
    expect(compose_up).to include("syrus_build_local_base_image dev")
    expect(helper).to include("if syrus_registry_cache_enabled; then")
    expect(helper).to include('cache_ref="$(syrus_docker_cache_ref)"')
    expect(helper).to include("--cache-from \"type=registry,ref=${cache_ref}\"")
    # ignore-error keeps a cache-export failure (403 / disk) from killing the build.
    expect(helper).to include("--cache-to \"type=registry,ref=${cache_ref},mode=max,ignore-error=true\"")
    expect(helper).to include("syrus_docker_build_image worker-dev \"$git_sha\"")
  end

  it "uses the same cache helper for publishing and deploying images" do
    expect(publish_image).to include(". ./bin/docker-image-lib")
    expect(publish_image).to include('CACHE_REF="$(syrus_docker_cache_ref)"')
    expect(publish_image).to include("syrus_docker_buildx_image worker-dev \"$GIT_SHA\"")
    expect(publish_image).to include("syrus_docker_build_image worker-dev \"$GIT_SHA\"")

    expect(deploy).to include('. "${SCRIPT_DIR}/docker-image-lib"')
    expect(deploy).to include("syrus_docker_build_image app \"$SHA\"")
    expect(deploy).to include("syrus_docker_build_image worker-dev \"$SHA\"")
    expect(deploy).to include("syrus_verify_pushed \"$1\" \"$2\"")
  end

  it "bakes the release version into published images via the shared helpers" do
    # The Dockerfile declares SYRUS_VERSION next to GIT_SHA in BOTH runnable
    # stages (app for web pods, worker-dev for the distribution image), the
    # helpers always forward it (empty when absent — the Dockerfile default),
    # and bin/publish-image passes the version it is publishing. Callers that
    # never publish releases (deploy, compose-up, build-local-image) pass no
    # --version and get dev images with an empty SYRUS_VERSION.
    dockerfile = File.read(File.join(root, "Dockerfile"))
    expect(dockerfile.scan('ARG SYRUS_VERSION=""').size).to eq(2)
    expect(dockerfile.scan("ENV SYRUS_VERSION=$SYRUS_VERSION").size).to eq(2)

    expect(helper.scan("--version=*)").size).to eq(2)
    expect(helper.scan('--build-arg "SYRUS_VERSION=$syrus_version"').size).to eq(3)

    expect(publish_image.scan('--version="$VERSION"').size).to eq(3)

    build_local_image = File.read(File.join(root, "bin/build-local-image"))
    expect(build_local_image).not_to include("--version=")
    expect(deploy).not_to include("--version=")
  end

  it "bakes the build timestamp into published and locally built images" do
    # SYRUS_BUILT_AT rides the same plumbing as SYRUS_VERSION (both Dockerfile
    # stages, all three helper invocations) and feeds the BuildBadge's hover
    # tooltip — the fastest read on which part of a diverged app/backend pair
    # is older. publish-image derives ONE timestamp up front FROM THE SOURCE
    # (HEAD's committer date, UTC — deterministic, so release.yml's two
    # native-arch legs bake the identical value into the single released
    # manifest; SYRUS_BUILT_AT still overrides, non-git trees fall back to
    # "now") and every build site bakes that same value; build-local-image
    # stamps dev images with the wall clock. deploy/compose-up pass nothing
    # and stay tooltip-less.
    dockerfile = File.read(File.join(root, "Dockerfile"))
    expect(dockerfile.scan('ARG SYRUS_BUILT_AT=""').size).to eq(2)
    expect(dockerfile.scan("ENV SYRUS_BUILT_AT=$SYRUS_BUILT_AT").size).to eq(2)

    expect(helper.scan("--built-at=*)").size).to eq(2)
    expect(helper.scan('--build-arg "SYRUS_BUILT_AT=$syrus_built_at"').size).to eq(3)

    expect(publish_image).to include(
      %q{BUILT_AT="${SYRUS_BUILT_AT:-$(TZ=UTC git show -s --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%SZ' HEAD 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)}"}
    )
    expect(publish_image.scan('--built-at="$BUILT_AT"').size).to eq(3)

    build_local_image = File.read(File.join(root, "bin/build-local-image"))
    expect(build_local_image).to include('BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"')
    expect(build_local_image).to include('syrus_build_local_backend_image "$IMAGE" "$GIT_SHA" --built-at="$BUILT_AT"')
    expect(deploy).not_to include("--built-at=")
  end

  it "keeps the shared build module's by-digest rebuild in lockstep with publish-image's build args" do
    # The backend build lives in the reusable _build-app.yml module now (called
    # by both release.yml and test-build.yml). It pushes each arch with a raw
    # `docker buildx build` that must be a pure cache hit of what
    # bin/publish-image built and tested. A missing build-arg there silently
    # rebuilds a DIFFERENT image (empty SYRUS_VERSION / SYRUS_BUILT_AT) than the
    # one the integration gate validated. The timestamp is DERIVED FROM THE
    # SOURCE (HEAD's committer date, UTC) with the identical expression in the
    # build step and the push step — and, because it is deterministic, in BOTH
    # matrix legs, so the two arch images in the single released multi-arch
    # manifest carry one timestamp. No GITHUB_ENV hand-off, no wall clock
    # anywhere in the release image path.
    build_yml = File.read(File.join(root, ".github/workflows/_build-app.yml"))
    expect(build_yml).to include('--build-arg "GIT_SHA=$(git rev-parse --short HEAD)"')
    expect(build_yml).to include('--build-arg "SYRUS_VERSION=$VERSION"')
    expect(build_yml).to include('--build-arg "SYRUS_BUILT_AT=$SYRUS_BUILT_AT"')
    git_stamp = %q{SYRUS_BUILT_AT="$(TZ=UTC git show -s --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%SZ' HEAD)"}
    expect(build_yml.scan(git_stamp).size).to eq(2)
    expect(build_yml).not_to include('SYRUS_BUILT_AT="$(date')
    expect(build_yml).not_to include('SYRUS_BUILT_AT=${SYRUS_BUILT_AT:-}')
  end

  it "verifies pushes through imagetools, not a hand-rolled base64 bearer token" do
    # Regression: syrus_verify_pushed used to base64-encode the token into an
    # `Authorization: Bearer` header for a raw curl. GNU `base64` wraps at 76
    # columns, so a >57-byte token (the Actions GITHUB_TOKEN) gained an embedded
    # newline that broke the request on Linux runners (curl exit 43) — invisible
    # on macOS (no wrapping) and never exercised by the --no-push dry run. It
    # now authenticates through the docker credential store that just pushed.
    verify = helper[/syrus_verify_pushed\(\)[\s\S]*?\n}/]
    # Assert on the code, not the comment that explains the removed bug.
    code = verify.lines.reject { |l| l.strip.start_with?("#") }.join
    expect(code).to include('docker buildx imagetools inspect "${repo}:${tag}"')
    expect(code).not_to include("base64")
    expect(code).not_to include("curl")
    expect(code).not_to match(/Authorization:\s*Bearer/)
  end

  it "lets Docker integration tests run without a checked-in local env file" do
    expect(test_docker).to include("ensure_compose_env()")
    expect(test_docker).to include("if [ -e .env ] || [ -L .env ]; then")
    expect(test_docker).to include('ln -s "$ITEST_ENV_FILE" .env')
    expect(test_docker).to include('rm -f .env')
    expect(test_docker).to include('rm -f "$ITEST_ENV_FILE"')
    expect(test_docker).to include("compose.env.example")
  end

  it "keeps the search database writable for web boot paths" do
    expect(compose_yml).to include("      - syrus-search:/home/rails/.syrus-search\n")
    expect(compose_yml).not_to include("syrus-search:/home/rails/.syrus-search:ro")
  end
end
