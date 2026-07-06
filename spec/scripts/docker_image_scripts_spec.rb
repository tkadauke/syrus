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
    expect(deploy).to include('patch_search_mount "$kubeconfig" "$namespace" "syrus-web" "false"')
    expect(deploy).to include('"fsGroup": 1000')
    expect(deploy).to include('"fsGroupChangePolicy": "OnRootMismatch"')

    expect(compose_yml).to include("      - syrus-search:/home/rails/.syrus-search\n")
    expect(compose_yml).not_to include("syrus-search:/home/rails/.syrus-search:ro")
  end
end
