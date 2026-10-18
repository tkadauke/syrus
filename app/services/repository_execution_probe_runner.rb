require "fileutils"

class RepositoryExecutionProbeRunner
  COMMAND_TIMEOUT = 10.minutes.to_i
  TOOLCHAIN_TIMEOUT = 5.minutes.to_i
  OUTPUT_LIMIT = 16.kilobytes

  def initialize(probe, git: GitRunner.new)
    @probe = probe
    @repository = probe.repository
    @git = git
    @path = WorkflowWorkspace.data_root.join("execution-probes", probe.id.to_s)
    @commands = []
  end

  def call
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    probe.update!(status: "running", started_at: Time.current, result: {})
    FileUtils.rm_rf(path)
    FileUtils.mkdir_p(path.dirname)
    clone!
    clone_bytes = disk_bytes
    revision = git_output("rev-parse", "HEAD").strip
    plan = RepoPrepPlan.for(path)
    grade = RepoGradePlan.for(path)
    signal = RepoGradeSignals.for(path).candidates.first

    toolchain = run_command("mise install", timeout: TOOLCHAIN_TIMEOUT, kind: "toolchain", required: true) if version_declared?
    prepare = toolchain&.fetch("success") == false ? [] : plan.commands.map do |command|
      run_command(command, timeout: COMMAND_TIMEOUT, kind: "prepare", required: !plan.guessed?)
    end
    grader_definition = grade.graders.first
    grader_command = grader_definition&.command || signal&.run
    grader = if grader_command && prepare.all? { |entry| entry["success"] }
      run_command(grader_command, timeout: grader_timeout(grader_definition), kind: grader_definition ? "grader" : "grader_discovery", required: grader_definition&.required)
    end

    finish!(revision:, clone_bytes:, toolchain:, prepare:, grader:, duration: elapsed(started))
  rescue StandardError => e
    probe.update!(status: "failed", completed_at: Time.current, result: {
      "summary" => "Probe failed before repository commands completed.",
      "failure" => { "class" => e.class.name, "message" => GitRunner.redact(e.message) },
      "commands" => @commands, "cleanup" => "pending"
    })
  ensure
    cleanup!
  end

  private

  attr_reader :probe, :path

  def clone!
    GithubAuthenticatedGit.run(repository: @repository, user: probe.requested_by, git: @git, operation_type: "repository_execution_probe") do |url|
      @git.run("clone", "--branch", @repository.default_branch, "--depth", "1", "--no-tags", url, path.to_s)
    end
    @git.run("remote", "set-url", "origin", @repository.remote_url, chdir: path.to_s)
  end

  def git_output(*args) = @git.run(*args, chdir: path.to_s)
  def version_declared?
    return true if Steps::Prepare::UNIVERSAL_MISE_VERSION_FILES.any? { |file| path.join(file).file? }

    Syrus::PluginRegistry.providers_for(:prepare_detector).any? do |detector|
      file = detector.mise_version_file
      file.present? && path.join(file).file?
    end
  end

  def grader_timeout(grader)
    configured = grader&.timeout_minutes.to_i.minutes.to_i
    configured.positive? ? [ configured, COMMAND_TIMEOUT ].min : COMMAND_TIMEOUT
  end

  def run_command(command, timeout:, kind:, required: false)
    output = +""
    result = ProcessRunner.new(
      env: probe_env, command: [ "bash", "-c", command ], mounts: ProcessRunner.mounts(path),
      network: "prepare", timeout:, kind: "repository_execution_probe",
      on_output_chunk: ->(chunk) { output << chunk; output = output.byteslice(-OUTPUT_LIMIT, OUTPUT_LIMIT) if output.bytesize > OUTPUT_LIMIT }
    ).run
    entry = {
      "kind" => kind, "command" => command, "required" => !!required,
      "success" => result.success? && !result.timed_out?, "exit_status" => result.exit_status,
      "timed_out" => result.timed_out?, "duration_s" => result.duration_s&.round(2),
      "output_tail" => output.scrub.strip.presence,
      "could_not_start" => result.exit_status.to_i.in?([ 126, 127 ])
    }.compact
    @commands << entry
    entry
  end

  def probe_env
    base = Steps::Prepare.prep_env_forward.index_with { |key| ENV[key] }.compact
    scope = PrepareScope.new(namespace: "repository_probe", id: probe.id, repository: @repository)
    base.merge(Steps::Prepare.prep_extra_env(scope:, workspace_path: path))
  end

  def finish!(revision:, clone_bytes:, toolchain:, prepare:, grader:, duration:)
    commands = [ toolchain, *prepare, grader ].compact
    start_failure = commands.any? { |entry| entry["required"] && entry["could_not_start"] }
    toolchain_failure = toolchain && !toolchain["success"]
    failure = commands.any? { |entry| !entry["success"] }
    status = start_failure ? "blocked" : (toolchain_failure || failure ? "failed" : (grader ? "succeeded" : "warning"))
    summary = if start_failure
      "A required command could not start; the first implementation run is blocked."
    elsif toolchain_failure
      "Toolchain installation failed."
    elsif failure
      "A disposable probe command failed."
    elsif grader
      "Prepare and bounded grader probe succeeded."
    else
      "Prepare succeeded, but no grader command was configured or discovered."
    end
    final_bytes = disk_bytes
    probe.update!(status:, revision:, completed_at: Time.current, result: {
      "summary" => summary, "duration_s" => duration.round(2), "clone_bytes" => clone_bytes,
      "final_bytes" => final_bytes, "disk_growth_bytes" => [ final_bytes - clone_bytes, 0 ].max,
      "commands" => commands, "missing_executables" => missing_executables(commands),
      "missing_services" => missing_services(commands), "cleanup" => "pending"
    })
  end

  def missing_executables(commands)
    commands.filter_map do |entry|
      next unless entry["could_not_start"]

      entry["output_tail"].to_s[/\b([A-Za-z0-9_.-]+): command not found\b/, 1] || entry["command"].to_s.split.first
    end.uniq
  end

  def missing_services(commands)
    text = commands.filter_map { |entry| entry["output_tail"] }.join("\n")
    %w[postgresql mysql redis docker elasticsearch minio].select do |service|
      text.match?(/(?:connection refused|could not connect|not running|cannot connect)[^\n]{0,120}\b#{Regexp.escape(service)}\b|\b#{Regexp.escape(service)}\b[^\n]{0,120}(?:connection refused|could not connect|not running|cannot connect)/i)
    end
  end

  def cleanup!
    root = WorkflowWorkspace.data_root.join("execution-probes").to_s + "/"
    FileUtils.rm_rf(path) if path.to_s.start_with?(root)
    return unless probe.persisted?

    probe.update_columns(result: probe.reload.result.to_h.merge("cleanup" => path.exist? ? "failed" : "completed"))
  rescue StandardError => e
    Rails.logger.warn("[RepositoryExecutionProbe] cleanup failed for probe ##{probe.id}: #{e.class}: #{e.message}")
  end

  def disk_bytes
    Dir.glob(path.join("**", "*").to_s, File::FNM_DOTMATCH).sum { |entry| File.file?(entry) ? File.size(entry) : 0 }
  end

  def elapsed(started) = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end
