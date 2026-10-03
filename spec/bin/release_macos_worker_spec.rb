# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "native macOS worker release artifact" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/release-macos-worker") }
  let(:version) { "v1.2.3-test.4" }
  let(:output_dir) { File.join(root, "dist/releases/#{version}/macos-worker") }

  def git(*args)
    stdout, status = Open3.capture2("git", *args, chdir: root)
    expect(status).to be_success
    stdout.strip
  end

  def tar_output(*args)
    stdout, status = Open3.capture2("tar", *args, chdir: root)
    expect(status).to be_success
    stdout
  end

  before do
    FileUtils.rm_rf(output_dir)
  end

  after do
    FileUtils.rm_rf(output_dir)
  end

  it "packages the source checkout, worker metadata, and checksum file" do
    short_sha = git("rev-parse", "--short", "HEAD")
    full_sha = git("rev-parse", "HEAD")
    artifact_name = "syrus-worker-macos-arm64-#{short_sha}.tar.gz"
    artifact_path = File.join(output_dir, artifact_name)

    stdout, stderr, status = Open3.capture3(
      { "SYRUS_BUILT_AT" => "2026-10-03T12:34:56Z" },
      "bash",
      script,
      version,
      "--skip-clean-check",
      chdir: root
    )

    expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(File).to exist(artifact_path)
    expect(File).to exist(File.join(output_dir, "SHA256SUMS-macos-worker.txt"))

    entries = tar_output("-tzf", artifact_path).lines.map(&:strip)
    root_entry = "syrus-worker-macos-arm64-#{short_sha}"
    expect(entries).to include("#{root_entry}/bin/macos-worker")
    expect(entries).to include("#{root_entry}/bin/macos-worker-check")
    expect(entries).to include("#{root_entry}/config/launchd/com.syrus.worker.plist")
    expect(entries).to include("#{root_entry}/Gemfile")
    expect(entries).to include("#{root_entry}/Gemfile.lock")
    expect(entries).to include("#{root_entry}/package.json")
    expect(entries).to include("#{root_entry}/package-lock.json")
    expect(entries).to include("#{root_entry}/GIT_SHA")
    expect(entries).to include("#{root_entry}/SYRUS_VERSION")
    expect(entries).to include("#{root_entry}/config/syrus-worker-release.json")
    expect(entries).not_to include("#{root_entry}/vendor/bundle/")
    expect(entries).not_to include("#{root_entry}/node_modules/")
    expect(entries).not_to include("#{root_entry}/dist/")

    manifest_json = tar_output("-xOzf", artifact_path, "#{root_entry}/config/syrus-worker-release.json")
    manifest = JSON.parse(manifest_json)
    expect(manifest).to include(
      "artifact" => artifact_name,
      "component" => "macos-worker",
      "platform" => "macos",
      "arch" => "arm64",
      "version" => "1.2.3-test.4",
      "git_sha" => short_sha,
      "full_git_sha" => full_sha,
      "built_at" => "2026-10-03T12:34:56Z",
      "entrypoint" => "bin/macos-worker",
      "health_check" => "bin/macos-worker-check",
      "launchd_plist" => "config/launchd/com.syrus.worker.plist",
      "queue_config" => "config/queue.compute.yml",
      "dependency_policy" => "host_activation"
    )

    checksum_stdout, checksum_stderr, checksum_status = Open3.capture3(
      "shasum",
      "-a",
      "256",
      "-c",
      "SHA256SUMS-macos-worker.txt",
      chdir: output_dir
    )
    expect(checksum_status).to be_success, "expected checksum success, got stdout=#{checksum_stdout.inspect} stderr=#{checksum_stderr.inspect}"
  end
end
