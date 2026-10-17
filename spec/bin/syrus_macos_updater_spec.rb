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

  def make_artifact(dir, sha:, command_log: nil)
    release_root = File.join(dir, "artifact-root")
    FileUtils.mkdir_p(File.join(release_root, "bin"))
    File.write(File.join(release_root, "GIT_SHA"), "#{sha}\n")
    File.write(File.join(release_root, "package.json"), "{}\n")
    File.write(File.join(release_root, "package-lock.json"), %({"lockfileVersion":3,"packages":{}}\n))
    check_body = if command_log
      "#!/usr/bin/env bash\nprintf 'check %s\\n' \"$*\" >> #{command_log.inspect}\n"
    else
      "#!/usr/bin/env bash\nexit 0\n"
    end
    write_executable(File.join(release_root, "bin/macos-worker-check"), check_body)
    write_executable(File.join(release_root, "bin/syrus-macos-updater"), "#!/usr/bin/env bash\nexit 0\n")
    artifact = File.join(dir, "worker.tar.gz")
    system("tar", "-C", dir, "-czf", artifact, "artifact-root")
    artifact
  end

  def sha256(path)
    stdout, status = Open3.capture2("shasum", "-a", "256", path)
    expect(status).to be_success
    stdout.split.first
  end

  def signing_key(dir)
    private_key = File.join(dir, "update-private.pem")
    public_key = File.join(dir, "update-public.pem")
    system("openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", private_key,
      out: File::NULL, err: File::NULL)
    system("openssl", "pkey", "-in", private_key, "-pubout", "-out", public_key, out: File::NULL, err: File::NULL)
    [ private_key, public_key ]
  end

  def signature(path, private_key)
    raw_signature = File.join(File.dirname(path), "artifact.sig")
    system("openssl", "dgst", "-sha256", "-sign", private_key, "-out", raw_signature, path)
    [ File.binread(raw_signature) ].pack("m0")
  end

  def write_metadata(path, artifact:, sha:, artifact_sha: sha256(artifact), artifact_signature: nil, retention_count: 2, drain: nil)
    private_key, public_key = signing_key(File.dirname(path))
    artifact_signature ||= signature(artifact, private_key)
    payload = {
      enabled: true,
      retention_count: retention_count,
      drain: drain,
      desired: {
        version: "1.2.3",
        git_sha: sha,
        artifact_url: "file://#{artifact}",
        artifact_sha256: artifact_sha,
        artifact_signature: artifact_signature,
        artifact_name: File.basename(artifact)
      }
    }.compact
    File.write(path, JSON.generate(payload))
    public_key
  end

  def write_env(path, metadata:)
    File.write(path, <<~ENV)
      SYRUS_UPDATE_METADATA_URL=file://#{metadata}
      SYRUS_MACOS_UPDATE_PUBLIC_KEY_FILE=#{File.join(File.dirname(metadata), "update-public.pem")}
      SYRUS_MACOS_UPDATE_ALLOW_FILE_URLS=1
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

  it "passes worker identity when polling the Syrus metadata endpoint" do
    Dir.mktmpdir do |raw_dir|
      # macOS symlinks /var to /private/var, so mktmpdir hands back an
      # unresolved path while File.realpath (and the updater's own `pwd -P`)
      # report the resolved one. Resolve once here so every path derived below
      # is in the same namespace as what we compare it against.
      dir = File.realpath(raw_dir)
      env_file = File.join(dir, "worker.env")
      data_root = File.join(dir, "data")
      request_file = File.join(dir, "request.txt")
      FileUtils.mkdir_p(data_root)
      File.write(File.join(data_root, ".syrus-worker-storage-id"), "storage a\n")
      File.write(env_file, <<~ENV)
        SYRUS_APP_HOST=https://syrus.example.test/
        SYRUS_DATA_ROOT=#{data_root}
      ENV
      bin_dir = stub_prepare_commands(dir)
      write_executable(File.join(bin_dir, "curl"), <<~BASH)
        #!/usr/bin/env bash
        printf '%s\\n' "$*" > "#{request_file}"
        printf '{"enabled":false,"desired":{}}'
      BASH

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}" },
        "bash",
        script,
        "--env-file",
        env_file,
        "--once"
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      request = File.read(request_file)
      expect(request).to include("https://syrus.example.test/api/v1/app/admin/macos_worker_update?")
      expect(request).to include("hostname=")
      expect(request).to include("worker_storage_key=storage-a")
    end
  end

  it "uses the scoped macOS worker token before the legacy API token" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      env_file = File.join(dir, "worker.env")
      request_file = File.join(dir, "request.txt")
      File.write(env_file, <<~ENV)
        SYRUS_APP_HOST=https://syrus.example.test/
        SYRUS_DATA_ROOT=#{dir}
        SYRUS_MACOS_WORKER_TOKEN=scoped-token
        SYRUS_API_TOKEN=legacy-admin-token
      ENV
      bin_dir = stub_prepare_commands(dir)
      write_executable(File.join(bin_dir, "curl"), <<~BASH)
        #!/usr/bin/env bash
        printf '%s\\n' "$*" > "#{request_file}"
        printf '{"enabled":false,"desired":{}}'
      BASH

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}" },
        "bash",
        script,
        "--env-file",
        env_file,
        "--once"
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      request = File.read(request_file)
      expect(request).to include("Authorization: Bearer scoped-token")
      expect(request).not_to include("legacy-admin-token")
    end
  end

  it "downloads, verifies, activates, and prunes releases" do
    Dir.mktmpdir do |raw_dir|
      # macOS symlinks /var to /private/var, so mktmpdir hands back an
      # unresolved path while File.realpath (and the updater's own `pwd -P`)
      # report the resolved one. Resolve once here so every path derived below
      # is in the same namespace as what we compare it against.
      dir = File.realpath(raw_dir)
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      current_link = File.join(install_root, "current")
      new_sha = "abc1234"
      FileUtils.mkdir_p(releases_dir)
      %w[old-a old-b old-c].each do |name|
        path = File.join(releases_dir, name)
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "GIT_SHA"), "#{name}\n")
      end
      File.symlink(File.join(releases_dir, "old-a"), current_link)

      artifact = make_artifact(dir, sha: new_sha)
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: new_sha, retention_count: 2)
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
      expect(File.realpath(current_link)).to eq(File.join(releases_dir, new_sha))
      expect(File.read(File.join(current_link, "GIT_SHA")).strip).to eq(new_sha)
      expect(Dir.children(releases_dir)).to include(new_sha)
      expect(Dir.children(releases_dir).length).to eq(2)
    end
  end

  it "drops privileges for preparation and restores root ownership before installing the privileged updater" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      current_link = File.join(install_root, "current")
      current_release = File.join(releases_dir, "aaa1111")
      command_log = File.join(dir, "commands.log")
      privileged_updater = File.join(install_root, "libexec", "syrus-macos-updater")
      FileUtils.mkdir_p([ current_release, File.dirname(privileged_updater) ])
      File.write(File.join(current_release, "GIT_SHA"), "aaa1111\n")
      File.symlink(current_release, current_link)

      artifact = make_artifact(dir, sha: "bbb2222", command_log: command_log)
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: "bbb2222")
      write_env(env_file, metadata: metadata)
      File.open(env_file, "a") do |file|
        file.puts "SYRUS_MACOS_SERVICE_USER=test-worker"
        file.puts "SYRUS_MACOS_PRIVILEGED_UPDATER_PATH=#{privileged_updater}"
      end

      bin_dir = stub_prepare_commands(dir)
      %w[bundle npm].each do |command|
        write_executable(File.join(bin_dir, command), <<~BASH)
          #!/usr/bin/env bash
          printf '#{command} %s\n' "$PWD $*" >> #{command_log.inspect}
        BASH
      end
      write_executable(File.join(bin_dir, "chown"), <<~BASH)
        #!/usr/bin/env bash
        printf 'chown %s\n' "$*" >> #{command_log.inspect}
      BASH
      write_executable(File.join(bin_dir, "sudo"), <<~BASH)
        #!/usr/bin/env bash
        printf 'sudo %s\n' "$*" >> #{command_log.inspect}
        while [[ "$1" == "-H" || "$1" == "-u" ]]; do
          if [[ "$1" == "-u" ]]; then shift 2; else shift; fi
        done
        exec "$@"
      BASH
      write_executable(File.join(bin_dir, "install"), <<~BASH)
        #!/usr/bin/env bash
        printf 'install %s\n' "$*" >> #{command_log.inspect}
        while [[ "$1" == -* ]]; do shift 2; done
        cp "$1" "$2"
        chmod 755 "$2"
      BASH

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{bin_dir}:#{ENV.fetch('PATH')}",
          "SYRUS_MACOS_INSTALL_ROOT" => install_root,
          "SYRUS_MACOS_CURRENT_LINK" => current_link,
          "SYRUS_MACOS_UPDATE_TEST_ROOT" => "1"
        },
        "bash", script, "--env-file", env_file, "--once", "--skip-restart"
      )

      expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      release_path = File.join(releases_dir, "bbb2222")
      commands = File.read(command_log)
      expect(commands).to include("sudo -H -u test-worker env")
      expect(commands).to include("bundle #{release_path}")
      expect(commands).to include("npm #{install_root}/shared/node/bbb2222")
      expect(commands).to include("check --env-file #{env_file}")
      expect(commands).to include("chown -R root:wheel #{release_path}")
      expect(commands).to include("install -o root -g wheel -m 755 #{release_path}/bin/syrus-macos-updater #{privileged_updater}")
      expect(File).to exist(privileged_updater)
      expect(File.stat(privileged_updater).mode & 0o777).to eq(0o755)
      expect(File.stat(release_path).mode & 0o022).to eq(0)
    end
  end

  # prune_releases decides what is stale by comparing each release directory
  # against the resolved target of the `current` symlink. `pwd -P` resolves
  # every symlink in a path, so if the install root is itself reached through
  # one, the release just activated did not match and was pruned as stale --
  # leaving `current` pointing at a directory that no longer existed, which
  # breaks the worker on its next start. A symlinked install path is ordinary
  # on macOS (/var and /tmp are both symlinks).
  it "keeps the activated release when the install root is reached through a symlink" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      real_root = File.join(dir, "real_install")
      install_root = File.join(dir, "install")
      FileUtils.mkdir_p(real_root)
      File.symlink(real_root, install_root)

      releases_dir = File.join(install_root, "releases")
      current_link = File.join(install_root, "current")
      new_sha = "abc1234"
      FileUtils.mkdir_p(releases_dir)
      %w[old-a old-b].each do |name|
        path = File.join(releases_dir, name)
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "GIT_SHA"), "#{name}\n")
      end
      File.symlink(File.join(releases_dir, "old-a"), current_link)

      artifact = make_artifact(dir, sha: new_sha)
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: new_sha, retention_count: 2)
      write_env(env_file, metadata: metadata)

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{stub_prepare_commands(dir)}:#{ENV.fetch("PATH")}",
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
      expect(Dir.children(releases_dir)).to include(new_sha)
      expect(File.realpath(current_link)).to eq(File.join(real_root, "releases", new_sha))
    end
  end

  it "honors install path overrides from the worker env file" do
    Dir.mktmpdir do |raw_dir|
      # macOS symlinks /var to /private/var, so mktmpdir hands back an
      # unresolved path while File.realpath (and the updater's own `pwd -P`)
      # report the resolved one. Resolve once here so every path derived below
      # is in the same namespace as what we compare it against.
      dir = File.realpath(raw_dir)
      install_root = File.join(dir, "env-install")
      releases_dir = File.join(install_root, "releases")
      current_link = File.join(install_root, "current")
      new_sha = "def5678"
      FileUtils.mkdir_p(releases_dir)
      FileUtils.mkdir_p(File.join(releases_dir, "aaaaaaa"))
      File.write(File.join(releases_dir, "aaaaaaa", "GIT_SHA"), "aaaaaaa\n")
      File.symlink(File.join(releases_dir, "aaaaaaa"), current_link)

      artifact = make_artifact(dir, sha: new_sha)
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: new_sha)
      write_env(env_file, metadata: metadata)
      File.open(env_file, "a") do |file|
        file.puts "SYRUS_MACOS_INSTALL_ROOT=#{install_root}"
      end
      path = "#{stub_prepare_commands(dir)}:#{ENV.fetch("PATH")}"

      stdout, stderr, status = Open3.capture3(
        { "PATH" => path },
        "bash",
        script,
        "--env-file",
        env_file,
        "--once",
        "--skip-restart"
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(File.realpath(current_link)).to eq(File.join(releases_dir, new_sha))
      expect(File.read(File.join(current_link, "GIT_SHA")).strip).to eq(new_sha)
    end
  end

  it "skips activation when the current release already matches the desired sha" do
    Dir.mktmpdir do |raw_dir|
      # macOS symlinks /var to /private/var, so mktmpdir hands back an
      # unresolved path while File.realpath (and the updater's own `pwd -P`)
      # report the resolved one. Resolve once here so every path derived below
      # is in the same namespace as what we compare it against.
      dir = File.realpath(raw_dir)
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      same_sha = "123abcd"
      current_release = File.join(releases_dir, same_sha)
      current_link = File.join(install_root, "current")
      FileUtils.mkdir_p(current_release)
      File.write(File.join(current_release, "GIT_SHA"), "#{same_sha}\n")
      File.symlink(current_release, current_link)

      artifact = make_artifact(dir, sha: same_sha)
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: same_sha)
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
      expect(stdout).to include("already current at #{same_sha}")
      expect(File.realpath(current_link)).to eq(current_release)
    end
  end

  it "does not activate a desired release until the drain directive allows updating" do
    Dir.mktmpdir do |raw_dir|
      # macOS symlinks /var to /private/var, so mktmpdir hands back an
      # unresolved path while File.realpath (and the updater's own `pwd -P`)
      # report the resolved one. Resolve once here so every path derived below
      # is in the same namespace as what we compare it against.
      dir = File.realpath(raw_dir)
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      current_release = File.join(releases_dir, "aaa1111")
      current_link = File.join(install_root, "current")
      FileUtils.mkdir_p(current_release)
      File.write(File.join(current_release, "GIT_SHA"), "aaa1111\n")
      File.symlink(current_release, current_link)

      artifact = make_artifact(dir, sha: "abc1234")
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: "abc1234", drain: { state: "draining" })
      write_env(env_file, metadata: metadata)

      stdout, stderr, status = Open3.capture3(
        { "SYRUS_MACOS_INSTALL_ROOT" => install_root, "SYRUS_MACOS_CURRENT_LINK" => current_link },
        "bash",
        script,
        "--env-file",
        env_file,
        "--once",
        "--dry-run"
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("no desired macOS worker release configured")
      expect(stdout).not_to include("would install abc1234")
      expect(File.realpath(current_link)).to eq(current_release)
    end
  end

  it "reports a failed checksum without flipping the current symlink" do
    Dir.mktmpdir do |raw_dir|
      # macOS symlinks /var to /private/var, so mktmpdir hands back an
      # unresolved path while File.realpath (and the updater's own `pwd -P`)
      # report the resolved one. Resolve once here so every path derived below
      # is in the same namespace as what we compare it against.
      dir = File.realpath(raw_dir)
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      current_release = File.join(releases_dir, "aaa1111")
      current_link = File.join(install_root, "current")
      report_file = File.join(dir, "report.jsonl")
      FileUtils.mkdir_p(current_release)
      File.write(File.join(current_release, "GIT_SHA"), "aaa1111\n")
      File.symlink(current_release, current_link)

      artifact = make_artifact(dir, sha: "bad2222")
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: "bad2222", artifact_sha: "0" * 64)
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

  it "rejects target shas that could escape the releases directory" do
    Dir.mktmpdir do |raw_dir|
      # macOS symlinks /var to /private/var, so mktmpdir hands back an
      # unresolved path while File.realpath (and the updater's own `pwd -P`)
      # report the resolved one. Resolve once here so every path derived below
      # is in the same namespace as what we compare it against.
      dir = File.realpath(raw_dir)
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      current_release = File.join(releases_dir, "aaa1111")
      current_link = File.join(install_root, "current")
      FileUtils.mkdir_p(current_release)
      File.write(File.join(current_release, "GIT_SHA"), "aaa1111\n")
      File.symlink(current_release, current_link)

      artifact = make_artifact(dir, sha: "fff9999")
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: "../escape")
      write_env(env_file, metadata: metadata)

      stdout, stderr, status = Open3.capture3(
        { "SYRUS_MACOS_INSTALL_ROOT" => install_root },
        "bash",
        script,
        "--env-file",
        env_file,
        "--once",
        "--skip-restart"
      )

      expect(status.exitstatus).to eq(1), "expected failure, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stderr).to include("desired git_sha must be a 7-40 character hex git SHA")
      expect(File).not_to exist(File.join(install_root, "escape"))
      expect(File.realpath(current_link)).to eq(current_release)
    end
  end

  it "rejects an artifact whose detached signature does not match" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      install_root = File.join(dir, "install")
      releases_dir = File.join(install_root, "releases")
      current_release = File.join(releases_dir, "aaa1111")
      current_link = File.join(install_root, "current")
      FileUtils.mkdir_p(current_release)
      File.write(File.join(current_release, "GIT_SHA"), "aaa1111\n")
      File.symlink(current_release, current_link)

      artifact = make_artifact(dir, sha: "bbb2222")
      metadata = File.join(dir, "metadata.json")
      env_file = File.join(dir, "worker.env")
      write_metadata(metadata, artifact: artifact, sha: "bbb2222", artifact_signature: [ "not a signature" ].pack("m0"))
      write_env(env_file, metadata: metadata)

      _stdout, stderr, status = Open3.capture3(
        { "SYRUS_MACOS_INSTALL_ROOT" => install_root, "SYRUS_MACOS_CURRENT_LINK" => current_link },
        "bash", script, "--env-file", env_file, "--once", "--skip-restart"
      )

      expect(status).not_to be_success
      expect(stderr).to include("detached signature verification failed")
      expect(File.realpath(current_link)).to eq(current_release)
      expect(File).not_to exist(File.join(releases_dir, "bbb2222"))
    end
  end

  it "rejects non-HTTPS metadata URLs unless the test-only file transport is explicitly enabled" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      File.write(env_file, "SYRUS_UPDATE_METADATA_URL=http://updates.example.test/metadata.json\n")

      _stdout, stderr, status = Open3.capture3("bash", script, "--env-file", env_file, "--once")

      expect(status).not_to be_success
      expect(stderr).to include("metadata URL must use https")
    end
  end
end
