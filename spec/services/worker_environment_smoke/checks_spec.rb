require "rails_helper"

RSpec.describe WorkerEnvironmentSmoke::Checks do
  # Records every command and answers from a script, so no check reaches a
  # real process.
  def scripted_shell(&responder)
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:run) do |argv, env: {}, chdir: nil, timeout: 10|
        @calls << { argv: argv, env: env, chdir: chdir, timeout: timeout }
        responder.call(argv, env, chdir)
      end
    end.new
  end

  def shell_result(**attrs) = WorkerEnvironmentSmoke::Shell::Result.new(**attrs)
  def ok(output = "") = shell_result(status: "ok", output: output, exit_status: 0)
  def missing = shell_result(status: "not_found", output: "", exit_status: 127)

  describe WorkerEnvironmentSmoke::Checks::Command do
    let(:check) { described_class.new(name: "gh", argv: %w[gh --version], advisory: true) }

    it "passes with the tool's first output line" do
      result = check.call(shell: scripted_shell { ok("\ngh version 2.95.0 (2026-06-17)\nhttps://github.com/cli/cli\n") }, env: {})

      expect(result).to include("status" => "passed", "detail" => "gh version 2.95.0 (2026-06-17)", "advisory" => true)
    end

    # The production symptom: "gh is unavailable on this worker".
    it "fails naming a tool that is not on PATH" do
      result = check.call(shell: scripted_shell { missing }, env: {})

      expect(result).to include("status" => "failed", "reason" => "`gh` is not on PATH", "essential" => false)
    end

    it "fails a tool that is on PATH but does not start" do
      broken = shell_result(status: "failed", output: "dyld: Library not loaded: /opt/homebrew/lib/libyaml.dylib\n", exit_status: 134)

      result = check.call(shell: scripted_shell { broken }, env: {})

      expect(result.fetch("reason")).to eq("`gh --version` exited 134: dyld: Library not loaded: /opt/homebrew/lib/libyaml.dylib")
    end

    it "fails a tool that hangs" do
      result = check.call(shell: scripted_shell { shell_result(status: "timed_out", output: "", exit_status: nil) }, env: {})

      expect(result.fetch("reason")).to eq("`gh --version` did not finish within 10s")
    end
  end

  describe WorkerEnvironmentSmoke::Checks::NativeExtension do
    it "compiles a trivial program with the PATH ruby's mkmf in a private temp directory" do
      shell = scripted_shell { ok("checking ...\nclang\n") }

      result = described_class.new.call(shell: shell, env: { "PATH" => "/usr/bin" })

      expect(result).to include("status" => "passed", "detail" => "clang")
      call = shell.calls.sole
      expect(call[:argv].first(2)).to eq(%w[ruby -rmkmf])
      expect(call[:argv].last).to include("try_link")
      expect(call[:chdir]).to include("syrus-env-smoke-cc-")
      expect(File.exist?(call[:chdir])).to be(false)
    end

    it "fails with the build error from mkmf.log" do
      shell = scripted_shell do |_argv, _env, chdir|
        File.write(File.join(chdir, "mkmf.log"), "conftest.c:1:10: fatal error: 'stdio.h' file not found\n")
        shell_result(status: "failed", output: "-e:1:in '<main>': a trivial C program does not compile and link with clang (RuntimeError)\n", exit_status: 1)
      end

      result = described_class.new.call(shell: shell, env: {})

      expect(result.fetch("status")).to eq("failed")
      expect(result.fetch("reason")).to include("does not compile and link", "'stdio.h' file not found")
    end
  end

  describe WorkerEnvironmentSmoke::Checks::MysqlClient do
    around do |example|
      Dir.mktmpdir("mysql-check-spec-") do |dir|
        @bin = File.join(dir, "bin")
        FileUtils.mkdir_p(@bin)
        example.run
      end
    end

    def install_mysql_config
      path = File.join(@bin, "mysql_config")
      File.write(path, "#!/bin/sh\n")
      File.chmod(0o755, path)
      path
    end

    let(:empty_fallbacks) { stub_const("#{described_class}::FALLBACK_DIRS", []) }

    # The production symptom: `bundle install` could not compile mysql2 on a
    # worker whose MySQL client libraries had gone away.
    it "fails when mysql2 would find no MySQL client at all" do
      empty_fallbacks
      shell = scripted_shell { raise "must not run a build without a client" }

      result = described_class.new.call(shell: shell, env: { "PATH" => @bin })

      expect(result).to include("status" => "failed", "essential" => false)
      expect(result.fetch("reason")).to include("no mysql_config found")
    end

    it "builds against the mysql_config on PATH, the way mysql2's extconf finds it" do
      empty_fallbacks
      config = install_mysql_config
      shell = scripted_shell { ok("checking for mysql.h... yes\n8.4.10\n") }

      result = described_class.new.call(shell: shell, env: { "PATH" => @bin })

      expect(result).to include("status" => "passed", "detail" => "8.4.10", "mysql_config" => config, "mysql_config_source" => "PATH")
      call = shell.calls.sole
      expect(call[:env]).to include("PROBE_MYSQL_CONFIG" => config)
      expect(call[:argv].last).to include("have_header", "have_func", "try_run")
    end

    it "prefers an explicit mysql2 build flag over PATH" do
      empty_fallbacks
      install_mysql_config
      shell = scripted_shell { ok("8.4.10\n") }

      result = described_class.new.call(shell: shell,
        env: { "PATH" => @bin, "BUNDLE_BUILD__MYSQL2" => "--with-mysql-config=/opt/syrus/tools/mysql-client/8.4.10/bin/mysql_config" })

      expect(result).to include("mysql_config" => "/opt/syrus/tools/mysql-client/8.4.10/bin/mysql_config", "mysql_config_source" => "BUNDLE_BUILD__MYSQL2")
    end

    it "fails when the client is found but mysql.h or the library is unusable" do
      empty_fallbacks
      install_mysql_config
      shell = scripted_shell do
        shell_result(status: "failed", output: "-e:9:in '<main>': the MySQL client library does not link with mysql_config --libs (RuntimeError)\n", exit_status: 1)
      end

      result = described_class.new.call(shell: shell, env: { "PATH" => @bin })

      expect(result.fetch("status")).to eq("failed")
      expect(result.fetch("reason")).to include("mysql2 build prerequisites failed", "does not link")
    end
  end

  describe WorkerEnvironmentSmoke::Checks::DataRoot do
    around do |example|
      Dir.mktmpdir("data-root-check-spec-") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "workflows", ".locks"))
        example.run
      end
    end

    let(:df_shell) do
      scripted_shell do |argv|
        raise "unexpected #{argv}" unless argv.first == "df"

        ok("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 971350180 700000000 239161064 75% /\n")
      end
    end

    it "proves flock, hardlink and rename on the real lock directory and leaves nothing behind" do
      result = described_class.new(root: @root).call(shell: df_shell, env: {})

      expect(result).to include("status" => "passed", "essential" => true, "path" => File.join(@root, "workflows", ".locks"))
      expect(result.fetch("available_bytes")).to eq(239_161_064 * 1024)
      expect(Dir.children(File.join(@root, "workflows", ".locks"))).to be_empty
    end

    # The production symptom: flock on the Mac worker's workflows/.locks
    # returned ENOTSUP after its data root moved.
    it "fails when the filesystem does not support flock" do
      allow_any_instance_of(File).to receive(:flock).and_raise(Errno::ENOTSUP)

      result = described_class.new(root: @root).call(shell: df_shell, env: {})

      expect(result).to include("status" => "failed", "essential" => true)
      expect(result.fetch("reason")).to include("flock failed", "ENOTSUP")
      expect(Dir.children(File.join(@root, "workflows", ".locks"))).to be_empty
    end

    it "fails when hardlinks are not supported" do
      allow(File).to receive(:link).and_raise(Errno::EPERM)

      result = described_class.new(root: @root).call(shell: df_shell, env: {})

      expect(result.fetch("reason")).to include("hardlink failed", "EPERM")
      expect(Dir.children(File.join(@root, "workflows", ".locks"))).to be_empty
    end

    it "fails when free space is below the minimum" do
      result = described_class.new(root: @root, min_free_bytes: 300_000_000 * 1024).call(shell: df_shell, env: {})

      expect(result.fetch("status")).to eq("failed")
      expect(result.fetch("reason")).to match(/only 228\.\d GiB free .* at least 286\.\d GiB is required/)
    end

    it "fails a data root that does not exist without creating it" do
      missing = File.join(@root, "nope")

      result = described_class.new(root: missing).call(shell: df_shell, env: {})

      expect(result).to include("status" => "failed", "reason" => "#{missing} does not exist")
      expect(File.exist?(missing)).to be(false)
    end
  end

  describe WorkerEnvironmentSmoke::Checks::TempDir do
    it "passes a writable TMPDIR" do
      Dir.mktmpdir do |dir|
        expect(described_class.new.call(shell: nil, env: { "TMPDIR" => dir })).to include("status" => "passed", "detail" => dir)
      end
    end

    it "fails a TMPDIR it cannot use" do
      result = described_class.new.call(shell: nil, env: { "TMPDIR" => "/nonexistent-syrus-tmp" })

      expect(result).to include("status" => "failed", "essential" => true)
    end
  end

  describe ".default" do
    it "adds step-kind declared checks and agent provider CLIs to the core checks" do
      provider = Class.new do
        def self.provider_key = "codex"
        def self.worker_environment_check = %w[codex --version]
      end
      allow(Syrus::Plugin::ServiceProvider).to receive(:providers).and_call_original
      allow(Syrus::Plugin::ServiceProvider).to receive(:providers).with(:agent_provider).and_return([ provider ])
      entry = Step::Kind::Entry.new(kind: "visual_check", handler: "Noop", label: "Visual", style: "", agentic: true,
        worker_checks: [ { name: "browser", command: %w[playwright-mcp --version] } ])
      allow(Step::Kind).to receive(:entries).and_return(Step::Kind.entries + [ entry, entry ])

      names = described_class.default(env: {}, data_root: "/tmp").map(&:name)

      expect(names).to include("workflow_data_root", "tmp", "git", "gh", "c_compiler", "mysql_client", "browser", "agent_cli_codex")
      expect(names.count("browser")).to eq(1)
    end

    it "contributes nothing from a provider that names no CLI or raises" do
      quiet = Class.new { def self.provider_key = "muse" }
      broken = Class.new do
        def self.provider_key = "agy"
        def self.worker_environment_check = raise("boom")
      end
      allow(Syrus::Plugin::ServiceProvider).to receive(:providers).and_call_original
      allow(Syrus::Plugin::ServiceProvider).to receive(:providers).with(:agent_provider).and_return([ quiet, broken ])

      expect(described_class.agent_cli_checks).to eq([])
    end
  end
end

RSpec.describe WorkerEnvironmentSmoke::Shell do
  subject(:shell) { described_class.new }

  def capture(success:, stdout: "", stderr: "", exit_status: 0, timed_out: false)
    result = instance_double(ProcessRunner::Result, exit_status: exit_status, timed_out?: timed_out)
    instance_double(ProcessRunner::CaptureResult, success?: success, stdout: stdout, stderr: stderr, result: result)
  end

  def stub_runner(capture = nil, &block)
    runner = instance_double(ProcessRunner)
    block ? allow(runner).to(receive(:capture, &block)) : allow(runner).to(receive(:capture).and_return(capture))
    allow(ProcessRunner).to receive(:new).and_return(runner)
  end

  # Checks run the way prepare commands run, or they could pass where prepare
  # fails.
  it "runs a check like a prepare command: through ProcessRunner, on the prepare network, with only the given environment" do
    stub_runner(capture(success: true, stdout: "git version 2.54.0\n"))
    Dir.mktmpdir do |dir|
      result = shell.run(%w[git --version], env: { "PATH" => "/usr/bin" }, chdir: dir, timeout: 7)

      expect(result).to be_success
      expect(result.output).to eq("git version 2.54.0\n")
      expect(ProcessRunner).to have_received(:new).with(hash_including(
        env: { "PATH" => "/usr/bin" }, command: %w[git --version], network: "prepare", timeout: 7, kind: "runtime_probe",
        mounts: ProcessRunner.mounts(dir)
      ))
    end
  end

  it "classifies a missing command, a timeout, and a plain failure" do
    stub_runner(capture(success: false, exit_status: 127))
    expect(shell.run(%w[gh --version]).status).to eq("not_found")

    stub_runner(capture(success: false, exit_status: nil, timed_out: true))
    expect(shell.run(%w[gh --version]).status).to eq("timed_out")

    stub_runner(capture(success: false, stderr: "boom", exit_status: 2))
    expect(shell.run(%w[gh --version])).to have_attributes(status: "failed", output: "boom", exit_status: 2)

    stub_runner { raise Errno::ENOENT }
    expect(shell.run(%w[gh --version]).status).to eq("not_found")
  end
end
