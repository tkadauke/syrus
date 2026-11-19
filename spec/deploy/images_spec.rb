# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"
require "tempfile"

RSpec.describe Deploy::Images do
  let(:out) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: StringIO.new) }

  # One naming rule for every script that publishes these images, or a deploy
  # pushes an image the cluster's manifests -- or a release -- name
  # differently. Asserted across both deploy implementations and both release
  # workflows, because the rule is only worth anything if nothing restates it.
  describe "the shared plugin image naming rule" do
    it "produces the names the cluster manifests use" do
      names = `bash -c '. bin/docker-image-lib; syrus_plugin_images ghcr.io/tkadauke'`

      expect(names).to include("plugins/git_mirror/container ghcr.io/tkadauke/syrus-plugin-git-mirror")
      expect(names).to include("plugins/plugin_runtime/container ghcr.io/tkadauke/syrus-plugin-runtime")
    end

    it "is the only place any publisher derives them from" do
      publishers = %w[
        lib/deploy/images.rb
        bin/deploy-legacy
        bin/publish-plugin-images
        .github/workflows/release.yml
        .github/workflows/promote-release-images.yml
      ]

      publishers.each do |path|
        expect(File.read(File.join(DeploySpec::ROOT, path)))
          .to include("syrus_plugin_images"), "#{path} should use the shared helper"
      end
    end
  end

  describe "the registries this deploy owns" do
    subject(:images) do
      described_class.new(
        config: Deploy::Config.new(env: {}),
        repo: instance_double(Deploy::Repo, sha: "abc1234", release_version: "1.2.3", version_description: "1.2.3-4-gabc1234"),
        shell: shell, reporter: reporter
      )
    end

    let(:shell) do
      Deploy::Shell.new(reporter: reporter, clock: Deploy::Clock::Immediate.new, dry_run: true,
        stream: StringIO.new)
    end

    # What gets pinned, what gets a Flux override, and what gets verified in
    # the registry all come from this one list.
    it "is the backend, the worker image, and one per container-backed plugin" do
      expect(images.all_registries).to include(
        "ghcr.io/tkadauke/syrus",
        "ghcr.io/tkadauke/syrus-worker-dev",
        "ghcr.io/tkadauke/syrus-plugin-git-mirror"
      )
    end

    it "discovers plugin build directories alongside their registries" do
      expect(images.plugin_images).to include([ "plugins/git_mirror/container", "ghcr.io/tkadauke/syrus-plugin-git-mirror" ])
    end
  end

  # The toolchain is its own digest-tagged image, so a deploy whose local
  # BuildKit cache was pruned never rebuilds or re-ships it.
  describe "the worker toolchain image" do
    let(:ok) { Deploy::Shell::Result.new(argv: [], stdout: "", stderr: "", status: 0) }
    let(:missing) { Deploy::Shell::Result.new(argv: [], stdout: "", stderr: "", status: 1) }
    let(:shell) { instance_double(Deploy::Shell, dry_run?: false) }
    let(:key) { Deploy::DockerfileStages.from_file(File.join(DeploySpec::ROOT, "Dockerfile")).digest("worker-deps") }
    let(:deps_registry) { "ghcr.io/tkadauke/syrus-worker-deps" }
    let(:deps_image) { "#{deps_registry}:#{key}" }

    def images(env = {})
      described_class.new(
        config: Deploy::Config.new(env:),
        repo: instance_double(Deploy::Repo, sha: "abc1234", release_version: "1.2.3", version_description: "1.2.3-4-gabc1234"),
        shell:, reporter:
      )
    end

    before do
      allow(shell).to receive(:docker_lib).and_return(ok)
      allow(shell).to receive(:read).and_return(ok)
      allow(shell).to receive(:stream_write).and_return(ok)
    end

    it "builds worker-dev on the toolchain image, reusing it when the registry already has it" do
      images.send(:build_worker_dev!)

      expect(out.string).to include("#{deps_image}: toolchain unchanged; reusing the registry image")
      expect(shell).to have_received(:docker_lib).with("syrus_docker_build_image", "worker-dev", "abc1234",
        *Array.new(6) { anything }, "--build-arg", "WORKER_DEPS_IMAGE=#{deps_image}", any_args)
      expect(shell).not_to have_received(:docker_lib).with("syrus_docker_build_image", "worker-deps", any_args)
      expect(shell).to have_received(:docker_lib).with("syrus_docker_prune_old_repo_tags", key, deps_registry)
    end

    it "pulls a reused toolchain image into the local image store when it is missing there" do
      allow(shell).to receive(:read).with([ "docker", "image", "inspect", deps_image ]).and_return(missing)

      images.send(:build_worker_dev!)

      expect(shell).to have_received(:stream_write).with([ "docker", "pull", "--platform", "linux/amd64", deps_image ])
    end

    it "builds and pushes the toolchain image once, when the registry does not have it" do
      allow(shell).to receive(:docker_lib).with("syrus_verify_pushed", deps_registry, key, mode: :write).and_return(missing, ok)

      images.send(:build_worker_dev!)

      expect(out.string).to include("#{deps_image} build (linux/amd64, target=worker-deps)")
      expect(shell).to have_received(:docker_lib).with("syrus_docker_build_image", "worker-deps", "abc1234", any_args)
      expect(shell).to have_received(:stream_write).with([ "docker", "push", deps_image ])
    end

    it "rebuilds the toolchain image on request" do
      images("SYRUS_WORKER_DEPS_REFRESH" => "1").send(:build_worker_dev!)

      expect(shell).to have_received(:docker_lib).with("syrus_docker_build_image", "worker-deps", "abc1234", any_args)
    end

    it "falls back to the in-file stage when disabled" do
      images("SYRUS_WORKER_DEPS_IMAGE" => "0").send(:build_worker_dev!)

      expect(shell).not_to have_received(:docker_lib).with("syrus_docker_build_image", "worker-deps", any_args)
      expect(shell).to have_received(:docker_lib).with("syrus_docker_build_image", "worker-dev", "abc1234",
        *Array.new(6) { anything }, "-t", any_args)
    end
  end

  # The token is read into memory and handed to docker through the environment.
  # Everything a phase passes as an argument is eligible to be written to the
  # dry run's command stream, and that stream is a file an operator diffs and
  # keeps.
  describe "the GHCR token" do
    it "never reaches the recorded command stream" do
      stream = StringIO.new
      shell = Deploy::Shell.new(reporter: reporter, clock: Deploy::Clock::Immediate.new,
        dry_run: true, stream: stream)
      Tempfile.create("ghcr-token") do |token_file|
        token_file.write("ghp_super_secret_value")
        token_file.flush
        images = described_class.new(
          config: Deploy::Config.new(env: { "SYRUS_GHCR_TOKEN_FILE" => token_file.path }, dry_run: true),
          repo: instance_double(Deploy::Repo, sha: "abc1234", release_version: "1.2.3", version_description: "1.2.3-4-gabc1234"),
          shell: shell, reporter: reporter
        )

        images.ensure_available!
      end

      expect(stream.string).not_to include("ghp_super_secret_value")
      expect(stream.string).to include("syrus_ghcr_login")
    end
  end
end
