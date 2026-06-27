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
    expect(compose_up).to include(". ./bin/docker-image-lib")
    expect(compose_up).to include("if syrus_registry_cache_enabled; then")
    expect(compose_up).to include('CACHE_REF="$(syrus_docker_cache_ref)"')
    expect(compose_up).to include('syrus_docker_buildx_image worker-dev dev')
    expect(compose_up).to include("--cache-from \"type=registry,ref=${CACHE_REF}\"")
    expect(compose_up).to include("--cache-to \"type=registry,ref=${CACHE_REF},mode=max\"")
    expect(compose_up).to include("syrus_docker_build_image worker-dev dev")
  end

  it "uses the same cache helper for publishing and deploying images" do
    expect(publish_image).to include(". ./bin/docker-image-lib")
    expect(publish_image).to include('CACHE_REF="$(syrus_docker_cache_ref)"')
    expect(publish_image).to include("syrus_docker_buildx_image worker-dev \"$GIT_SHA\"")
    expect(publish_image).to include("syrus_docker_build_image worker-dev \"$GIT_SHA\"")

    expect(deploy).to include('. "${SCRIPT_DIR}/docker-image-lib"')
    expect(deploy).to include("syrus_docker_build_image app \"$SHA\"")
    expect(deploy).to include("syrus_docker_build_image worker-dev \"$SHA\"")
    expect(deploy).to include("syrus_verify_pushed \"$1\" \"$2\" \"$GHCR_TOKEN\"")
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
