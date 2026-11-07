# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

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
        repo: instance_double(Deploy::Repo, sha: "abc1234"),
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

  # The token is read into memory and handed to docker through the environment.
  # Everything a phase passes as an argument is eligible to be written to the
  # dry run's command stream, and that stream is a file an operator diffs and
  # keeps.
  describe "the GHCR token" do
    it "never reaches the recorded command stream" do
      stream = StringIO.new
      shell = Deploy::Shell.new(reporter: reporter, clock: Deploy::Clock::Immediate.new,
        dry_run: true, stream: stream)
      images = described_class.new(
        config: Deploy::Config.new(env: { "GHCR_TOKEN" => "ghp_super_secret_value" }, dry_run: true),
        repo: instance_double(Deploy::Repo, sha: "abc1234"),
        shell: shell, reporter: reporter
      )

      images.ensure_available!

      expect(stream.string).not_to include("ghp_super_secret_value")
      expect(stream.string).to include("syrus_ghcr_login")
    end
  end
end
