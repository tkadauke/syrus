# frozen_string_literal: true

require "open3"
require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "bin/publish-image" do
  let(:script_path) { File.expand_path("../../bin/publish-image", __dir__) }
  let(:script) { File.read(script_path, encoding: "UTF-8") }

  it "passes a bash syntax check" do
    _out, err, status = Open3.capture3("bash", "-n", script_path)
    expect(status.exitstatus).to eq(0), err
  end

  it "supports publishing test images from a fork" do
    # SYRUS_IMAGE_REPO + GHCR_USER let a fork publish e.g.
    # ghcr.io/<user>/syrus-backend without editing the script; upstream stays
    # the default so the release runbook is unchanged.
    expect(script).to include('IMAGE="${SYRUS_IMAGE_REPO:-ghcr.io/tkadauke/syrus-backend}"')
    expect(script).to include('GHCR_USER="${GHCR_USER:-tkadauke}"')
  end

  def run_publish(*args, plugin_exit: 0)
    Dir.mktmpdir("publish-image") do |root|
      bin = File.join(root, "bin")
      Dir.mkdir(bin)
      FileUtils.cp(script_path, File.join(bin, "publish-image"))
      File.write(File.join(bin, "docker-image-lib"), <<~SH)
        syrus_require_docker_daemon() { :; }
        syrus_disable_buildx_attestations() { :; }
        syrus_read_ghcr_token() { echo token; }
        syrus_registry_cache_enabled() { return 1; }
        syrus_ghcr_login() { echo login >> "$PUBLISH_LOG"; }
        syrus_docker_build_image() { echo local-build >> "$PUBLISH_LOG"; }
        syrus_docker_buildx_image() { echo "buildx $*" >> "$PUBLISH_LOG"; }
        syrus_worker_native_build_smoke() { :; }
        syrus_verify_pushed() { echo "verify $*" >> "$PUBLISH_LOG"; }
      SH
      File.write(File.join(bin, "publish-plugin-images"), <<~SH)
        #!/usr/bin/env bash
        echo "plugins $*" >> "$PUBLISH_LOG"
        exit #{plugin_exit}
      SH
      FileUtils.chmod(0o755, File.join(bin, "publish-plugin-images"))
      File.write(File.join(bin, "docker"), <<~SH)
        #!/usr/bin/env bash
        echo "docker $*" >> "$PUBLISH_LOG"
      SH
      FileUtils.chmod(0o755, File.join(bin, "docker"))
      log = File.join(root, "publish.log")
      env = {
        "HOME" => root,
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
        "PUBLISH_LOG" => log
      }
      _out, err, status = Open3.capture3(env, "bash", File.join(bin, "publish-image"), *args, chdir: root)
      return status, File.exist?(log) ? File.readlines(log, chomp: true) : [], err
    end
  end

  it "runs a multi-arch publish without registry cache arguments" do
    status, log, err = run_publish("1.2.3", "--multi-arch", "--skip-tests")

    expect(status).to be_success, err
    build = log.find { |line| line.start_with?("buildx ") }
    expect(build).to include("--platform linux/amd64,linux/arm64")
    expect(build).not_to include("--cache-from")
    expect(log.index("plugins 1.2.3 --no-login")).to be < log.index(build)
  end

  it "publishes plugin images before exposing the backend tags" do
    status, log, err = run_publish("1.2.3", "--skip-tests", plugin_exit: 1)

    expect(status).not_to be_success, err
    expect(log).to include("plugins 1.2.3 --no-login")
    expect(log.grep(/^docker push /)).to be_empty
    expect(log.grep(/^verify /)).to be_empty
  end
end
