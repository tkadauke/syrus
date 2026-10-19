class PreviewPreparation
  TIMEOUT_SECONDS = 10.minutes.to_i
  OUTPUT_TAIL_BYTES = 8.kilobytes

  class Error < StandardError
    attr_reader :details

    def initialize(message, details:)
      super(message)
      @details = details
    end
  end

  def initialize(workspace_path, project_id: nil, run: nil, workflow: nil, log: nil, preview_key: nil)
    @workspace_path = workspace_path.to_s
    @project_id = project_id.presence
    @run = run
    @workflow = workflow || run&.workflow
    @log = log || ->(_message, **) { }
    @preview_key = preview_key
  end

  def call
    commands.each_with_index do |(phase, command), index|
      @log.call("[preview_prepare] (#{index + 1}/#{commands.size}) #{phase}: $ #{command}", kind: "system")
      run_command!(phase, command)
    end

    record_local_setup!

    {
      "project_id" => @project_id,
      "commands" => commands.map(&:last),
      "prepared_at" => Time.current.iso8601
    }.compact
  rescue Error
    cleanup
    raise
  end

  private

  def source
    @source ||= PreviewCommandSource.new(@workspace_path, project_id: @project_id).resolve
  end

  def commands
    @commands ||= begin
      raise Error.new("no preview command configured", details: { "reason" => "no_preview_configured" }) unless source

      workflow_prepared = Array(@workflow&.artifact("prepared_workspace").to_h["commands"])
      locally_prepared = PreparedWorkspaceState.new(@workspace_path).commands
      already_prepared = workflow_prepared & locally_prepared
      setup = Array(source.setup_commands).reject { |command| already_prepared.include?(command) }
      [
        *setup.map { |command| [ "setup", command ] },
        *([ [ "seed", source.seed_command ] ] if source.seed_command.present?)
      ]
    end
  end

  def record_local_setup!
    prepared = PreparedWorkspaceState.new(@workspace_path)
    prepared.record!((prepared.commands + Array(source.setup_commands)).uniq)
  end

  def run_command!(phase, command)
    tail = +""
    result = ProcessRunner.new(
      env: process_env,
      command: [ "bash", "-c", command ],
      mounts: ProcessRunner.mounts(preview_workdir, read_write: @workspace_path),
      network: "prepare",
      timeout: TIMEOUT_SECONDS,
      kind: "preview",
      run: @run,
      workflow: @workflow,
      display_command: command,
      on_output_chunk: ->(chunk) {
        safe_chunk = CommandRedactor.redact(chunk.to_s)
        tail << safe_chunk
        tail.replace(tail.safe_byteslice(-OUTPUT_TAIL_BYTES, OUTPUT_TAIL_BYTES)) if tail.bytesize > OUTPUT_TAIL_BYTES
        @log.call(safe_chunk.chomp, kind: "system") if safe_chunk.present?
      }
    ).run
    return if result.success?

    details = {
      "reason" => "preview_#{phase}_failed",
      "phase" => phase,
      "command" => command,
      "exit_status" => result.exit_status,
      "timed_out" => result.timed_out?,
      "stopped" => result.stopped?,
      "operator_killed" => result.operator_killed?,
      "output_tail" => tail.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?").strip
    }
    raise Error.new("preview #{phase} failed#{result.timed_out? ? ' (timed out)' : ''}: #{command}", details: details)
  end

  def preview_workdir
    return @workspace_path if @project_id.blank?

    project = TargetGraph::Compiler.compile(@workspace_path).project(@project_id)
    project&.path.present? ? File.join(@workspace_path, project.path) : @workspace_path
  end

  def process_env
    env = ProcessRunner.forwarded_env(
      Steps::Prepare.prep_env_forward,
      extra: WorkspaceDependencyEnv.for(@workspace_path)
    )
    Array(source.unset_env).each { |name| env[name.to_s] = nil }
    env.merge(source.environment(key: @preview_key))
  end

  def cleanup
    return if source.cleanup_command.blank?

    ProcessRunner.new(
      env: process_env,
      command: [ "bash", "-c", source.cleanup_command ],
      mounts: ProcessRunner.mounts(preview_workdir, read_write: @workspace_path),
      network: "prepare",
      timeout: TIMEOUT_SECONDS,
      kind: "preview",
      run: @run,
      workflow: @workflow,
      display_command: source.cleanup_command
    ).run
  rescue StandardError => e
    Rails.logger.warn("[PreviewPreparation] database cleanup failed: #{CommandRedactor.redact(e.message)}")
  end
end
