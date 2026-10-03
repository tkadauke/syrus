# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "native macOS worker updater" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/syrus-macos-updater") }

  def write_executable(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def make_artifact(dir, sha:)
    release_root = File.join(dir, "artifact-root")
    FileUtils.mkdir_p(File.join(release_root, "bin"))
    File.write(File.join(release_root, "GIT_SHA"), "#{sha}\n")
    write_executable(File.join(release_root, "bin/macos-worker-check"), "#!/usr/bin/env bash\nexit 0\n")
    artifact = File.join(dir, "worker.tar.gz")
    system("tar", "-C", dir, "-czf", artifact, "artifact-root")
    artifact
  end

  def sha256(path)
    stdout, status = Open3.capture2("shasum", "-a", "256", path)
    expect(status).to be_success
    stdout.split.first
  end

  def write_metadata(path, artifact:, sha:, artifact_sha: sha256(artifact), retention_count: 2)
    File.write(path, JSON.generate(
      enabled: true,
      retention_count: retention_count,
      desired: {
        version: "1.2.3",
        git_sha: sha,
        artifact_url: "file://#{artifact}",
        artifact_sha256: artifact_sha,
        artifact_name: File.basename(artifact)
      }
    ))
  end

  def write_env(path, metadata:)
    File.write(path, <<~ENV)
      SYRUS_UPDATE_METADATA_URL=file://#{metadata}
      SYRUS_APP_HOST=https://syrus.example.test
      SYRUS_WORKER_POOL_NAME=macos-xcode
      SYRUS_WORKER_STORAGE_KEY=mac-mini-a
    ENV
  end

  def stub_prepare_commands(dir)
    bin_dir = File.join(dir, "bin")
    write_executable(File.join(bin_dir, "bundle"), "#!/usr/bin/env bash\nexit 0\n")
    write_executable(File.join(bin_dir, "npm"), "#!/usr/bin/env bash\nexit 0\n")
    bin_dir
  end

  it "downloads, verifies, activates, and prunes releases" do
    Dir.mktmpdir do |dir|
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      current_link = File.join(install_root, "current")
      FileUtils.mkdir_p(releases_dir)
      %w[old-a old-b old-c].each do |name|
        path = File.join(releases_dir, name)
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "GIT_SHA"), "#{name}\n")
      end
      File.symlink(File.join(releases_dir, "old-a"), current_link)

      artifact = make_artifact(dir, sha: "newsha")
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: "newsha", retention_count: 2)
      write_env(env_file, metadata: metadata)
      path = "#{stub_prepare_commands(dir)}:#{ENV.fetch("PATH")}"

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => path,
          "SYRUS_MACOS_INSTALL_ROOT" => install_root,
          "SYRUS_MACOS_CURRENT_LINK" => current_link
        },
        "bash",
        script,
        "--env-file",
        env_file,
        "--once",
        "--skip-restart"
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(File.realpath(current_link)).to eq(File.join(releases_dir, "newsha"))
      expect(File.read(File.join(current_link, "GIT_SHA")).strip).to eq("newsha")
      expect(Dir.children(releases_dir)).to include("newsha")
      expect(Dir.children(releases_dir).length).to eq(2)
    end
  end

  it "skips activation when the current release already matches the desired sha" do
    Dir.mktmpdir do |dir|
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      current_release = File.join(releases_dir, "same")
      current_link = File.join(install_root, "current")
      FileUtils.mkdir_p(current_release)
      File.write(File.join(current_release, "GIT_SHA"), "same\n")
      File.symlink(current_release, current_link)

      artifact = make_artifact(dir, sha: "same")
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: "same")
      write_env(env_file, metadata: metadata)

      stdout, stderr, status = Open3.capture3(
        { "SYRUS_MACOS_INSTALL_ROOT" => install_root, "SYRUS_MACOS_CURRENT_LINK" => current_link },
        "bash",
        script,
        "--env-file",
        env_file,
        "--once"
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("already current at same")
      expect(File.realpath(current_link)).to eq(current_release)
    end
  end

  it "reports a failed checksum without flipping the current symlink" do
    Dir.mktmpdir do |dir|
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      current_release = File.join(releases_dir, "old")
      current_link = File.join(install_root, "current")
      report_file = File.join(dir, "report.jsonl")
      FileUtils.mkdir_p(current_release)
      File.write(File.join(current_release, "GIT_SHA"), "old\n")
      File.symlink(current_release, current_link)

      artifact = make_artifact(dir, sha: "bad")
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: "bad", artifact_sha: "0" * 64)
      write_env(env_file, metadata: metadata)
      File.open(env_file, "a") do |file|
        file.puts "SYRUS_UPDATE_REPORT_URL=https://syrus.example.test/report"
        file.puts "SYRUS_API_TOKEN=test-token"
      end
      bin_dir = stub_prepare_commands(dir)
      write_executable(File.join(bin_dir, "curl"), <<~BASH)
        #!/usr/bin/env bash
        cat >> "#{report_file}"
        printf '\\n' >> "#{report_file}"
      BASH

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}",
          "SYRUS_MACOS_INSTALL_ROOT" => install_root,
          "SYRUS_MACOS_CURRENT_LINK" => current_link
        },
        "bash",
        script,
        "--env-file",
        env_file,
        "--once",
        "--skip-restart"
      )

      expect(status.exitstatus).to eq(1), "expected failure, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(File.realpath(current_link)).to eq(current_release)
      reported_states = File.readlines(report_file).map { |line| JSON.parse(line).dig("status", "state") }
      expect(reported_states).to include("failed")
    end
  end
end
