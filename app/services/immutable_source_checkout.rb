require "fileutils"
require "digest"
require "json"
require "securerandom"

class ImmutableSourceCheckout
  CHECKOUT_ROOT = ".syrus/immutable-checkouts/steps".freeze
  PREPARE_CACHE_ROOT = ".syrus/immutable-checkouts/prepare-cache".freeze
  PREPARE_CACHE_LOCK_ROOT = ".syrus/immutable-checkouts/prepare-cache-locks".freeze
  PREPARED_MARKER = ".syrus/immutable-source-prepared.json".freeze

  attr_reader :path

  def self.path_for(step)
    WorkflowWorkspace.path_for(step.workflow).join(CHECKOUT_ROOT, step.id.to_s)
  end

  def initialize(step, git: nil, log: nil)
    @step = step
    @workflow = step.workflow
    @job = @workflow.job
    @repository = @job.repository
    @git = git || GitRunner.new
    @log = log
    @path = self.class.path_for(step)
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def setup
    raise_infrastructure!("immutable source checkout is disabled for #{@repository.slug}") unless enabled_for_step?

    snapshot = source_snapshot
    log("[immutable_source_checkout] verifying source snapshot ##{snapshot.id} #{snapshot.source_ref}@#{snapshot.source_sha.first(7)}")
    materialize!(snapshot) unless valid_checkout?(snapshot)
    verify_head!(snapshot)
    ensure_exclude_entry
    prepare_cache = build_prepare_cache(snapshot)
    prepare_with_cache!(snapshot, prepare_cache)
    record_checkout_details!(snapshot)
    record_run_source_snapshot!(snapshot)
  end

  def branch_name
    source_snapshot.source_ref.to_s.delete_prefix("refs/heads/").presence || "HEAD"
  end

  def base_ref
    WorkflowWorkspace.base_ref_for(@job, workflow: @workflow)
  end

  private

  def enabled_for_step?
    @step.placement_policy == Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT &&
      Feature.distributed_workflow_dag_enabled?(@repository)
  end

  def source_snapshot
    snapshot_id = @step.details.to_h["source_snapshot_id"]
    raise_infrastructure!("workflow source snapshot metadata missing: source_snapshot_id") if snapshot_id.blank?

    @workflow.source_snapshots.find(snapshot_id)
  rescue ActiveRecord::RecordNotFound
    raise_infrastructure!("workflow source snapshot metadata missing: source_snapshot_id=#{snapshot_id}")
  end

  def materialize!(snapshot)
    FileUtils.rm_rf(path.to_s)
    FileUtils.mkdir_p(path.dirname)

    log("[immutable_source_checkout] materializing detached checkout at #{path}")
    @git.run("init", path.to_s)
    @git.run("remote", "add", "origin", @repository.remote_url, chdir: path.to_s)
    fetch_snapshot!(snapshot)
    @git.run("checkout", "--detach", snapshot.source_sha, chdir: path.to_s)
  rescue GitRunner::GitError => e
    raise_infrastructure!("immutable source checkout failed for #{snapshot.source_ref}@#{snapshot.source_sha}: #{e.message}")
  end

  def fetch_snapshot!(snapshot)
    log("[immutable_source_checkout] fetching #{snapshot.source_ref} for snapshot ##{snapshot.id}")
    authenticated_git("git_immutable_source_fetch") do |url|
      @git.run("fetch", "--no-tags", url, source_refspec(snapshot), chdir: path.to_s, env: @env)
    end
    record_origin_head!(snapshot)
    log("[immutable_source_checkout] fetched #{snapshot.source_ref} for snapshot ##{snapshot.id}")
  rescue GitRunner::GitError => e
    raise_infrastructure!("immutable source checkout missing ref #{snapshot.source_ref}: #{e.message}")
  end

  def source_refspec(snapshot)
    branch = source_branch(snapshot)
    return snapshot.source_ref if branch.blank?

    "+#{snapshot.source_ref}:refs/remotes/origin/#{branch}"
  end

  def record_origin_head!(snapshot)
    branch = source_branch(snapshot)
    return if branch.blank?

    @git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/#{branch}", chdir: path.to_s)
  rescue GitRunner::GitError
    nil
  end

  def source_branch(snapshot)
    snapshot.source_ref.to_s.delete_prefix("refs/heads/") if snapshot.source_ref.to_s.start_with?("refs/heads/")
  end

  def valid_checkout?(snapshot)
    return false unless path.join(".git").directory?

    @git.run("rev-parse", "HEAD", chdir: path.to_s).strip == snapshot.source_sha
  rescue GitRunner::GitError
    false
  end

  def verify_head!(snapshot)
    actual = @git.run("rev-parse", "HEAD", chdir: path.to_s).strip
    if actual == snapshot.source_sha
      log("[immutable_source_checkout] verified HEAD #{actual.first(7)} for snapshot ##{snapshot.id}")
      return
    end

    raise_infrastructure!(
      "immutable source checkout SHA mismatch: expected #{snapshot.source_sha}, got #{actual}"
    )
  rescue GitRunner::GitError => e
    raise_infrastructure!("immutable source checkout SHA mismatch: could not read HEAD: #{e.message}")
  end

  def authenticated_git(operation_type, &block)
    GithubAuthenticatedGit.run(
      repository: @repository,
      user: @job.user,
      git: @git,
      operation_type: operation_type,
      log: @log,
      &block
    )
  end

  def ensure_exclude_entry
    GitInfoExclude.ensure_entry!(path, WorkflowWorkspace::EXCLUDE_ENTRY)
    GitInfoExclude.ensure_entry!(path, WorkflowWorkspace::LOCK_SENTINEL)
  end

  def build_prepare_cache(snapshot)
    plan = RepoPrepPlan.for(path)
    PrepareCache.new(
      workflow: @workflow,
      step: @step,
      snapshot: snapshot,
      plan: plan,
      worker_storage_key: WorkerStorageIdentity.queue_key
    )
  end

  def prepare_with_cache!(snapshot, prepare_cache)
    prepare_cache.with_lock do
      if prepare_cache.hit?
        FileUtils.rm_rf(path.to_s)
        FileUtils.mkdir_p(path.dirname)
        copy_tree!(prepare_cache.path, path)
        verify_head!(snapshot)
        ensure_exclude_entry
        record_prepare_cache!(prepare_cache, "hit")
        log("[immutable_source_checkout] prepare cache hit: #{prepare_cache.short_cache_key}")
        return
      end

      record_prepare_cache!(prepare_cache, "miss")
      prepare!(snapshot, prepare_cache)
    end
  end

  def prepare!(snapshot, prepare_cache)
    plan = prepare_cache.plan
    log("[immutable_source_checkout] prepare source: #{plan.source}")
    log("[immutable_source_checkout] prepare note: #{plan.note}") if plan.note
    if plan.commands.empty?
      record_prepared!(snapshot, plan, prepare_cache)
      prepare_cache.store_from!(path)
      return
    end

    plan.commands.each_with_index do |command, index|
      log("[immutable_source_checkout] prepare (#{index + 1}/#{plan.commands.size}) $ #{command}")
      next if run_prepare_command(command)

      if plan.guessed?
        log("[immutable_source_checkout] guessed prepare command failed; continuing with immutable checkout unprepared")
        return
      end

      raise Steps::Base::StepFailed, "immutable source prepare command failed: #{command}"
    end

    record_prepared!(snapshot, plan, prepare_cache)
    prepare_cache.store_from!(path)
  end

  def record_prepared!(snapshot, plan, prepare_cache)
    FileUtils.mkdir_p(prepared_marker.dirname)
    prepared_marker.write(JSON.pretty_generate(
      "source_snapshot_id" => snapshot.id,
      "workflow_id" => @workflow.id,
      "source_sha" => snapshot.source_sha,
      "source_ref" => snapshot.source_ref,
      "worker_storage_key" => prepare_cache.worker_storage_key,
      "prepare_fingerprint" => prepare_cache.prepare_fingerprint,
      "prepare_cache_key" => prepare_cache.cache_key,
      "prepared_at" => Time.current.iso8601,
      "prepare_source" => plan.source
    ))
  end

  def prepared_marker
    path.join(PREPARED_MARKER)
  end

  def run_prepare_command(command)
    current_run = Thread.current[:syrus_current_run] || @step.latest_run
    span_plan = GraderCommandSpans::Plan.for(command)
    span_recorder = GraderCommandSpans::Recorder.new(
      run: current_run,
      step: @step,
      workflow: @workflow,
      plan: span_plan,
      sequence_offset: current_run.command_spans.maximum(:sequence).to_i
    ) if current_run
    runner_command = span_recorder ? span_recorder.wrap(span_plan.shell_command) : command

    result = ProcessRunner.new(
      env: prepare_env,
      command: [ "bash", "-c", runner_command ],
      chdir: path,
      timeout: Steps::Prepare::PER_COMMAND_TIMEOUT,
      kind: "prepare",
      run: current_run,
      workflow: @workflow,
      display_command: command,
      on_spawned_process: ->(process) { span_recorder.spawned_process = process if span_recorder },
      on_output_chunk: ->(chunk) {
        visible_chunk = span_recorder ? span_recorder.consume(chunk) : chunk
        log(visible_chunk.to_s.chomp) if visible_chunk.present?
      }
    ).run
    trailing_chunk = span_recorder&.flush_visible
    log(trailing_chunk.to_s.chomp) if trailing_chunk.present?
    span_recorder&.finalize!(
      exit_code: result.exit_status,
      timed_out: result.timed_out,
      stopped: result.stopped,
      operator_killed: result.operator_killed
    )

    result.success? && !result.timed_out?
  rescue StandardError
    span_recorder&.finalize!(exit_code: nil, timed_out: false)
    raise
  end

  def prepare_env
    ProcessRunner.forwarded_env(
      Steps::Prepare.prep_env_forward,
      extra: WorkspaceDependencyEnv.for(path).merge(
        Steps::Prepare.prep_extra_env(workflow: @workflow, workspace_path: path)
      )
    )
  end

  def log(message)
    @log&.call(message, kind: "system")
  end

  def raise_infrastructure!(message)
    raise WorkflowSourceSnapshots::InfrastructureStateError, message
  end

  def copy_tree!(source, destination)
    FileUtils.mkdir_p(destination)
    FileUtils.cp_r(source.children.map(&:to_s), destination.to_s, preserve: true)
  end

  def record_prepare_cache!(prepare_cache, status)
    @step.update!(details: @step.details.to_h.merge(
      "prepare_cache" => prepare_cache.details(status)
    ))
  end

  def record_checkout_details!(snapshot)
    prepare_cache_details = @step.details.to_h["prepare_cache"].to_h
    @step.update!(details: @step.details.to_h.merge(
      "immutable_source_checkout" => {
        "worker_hostname" => SyrusVersion.hostname,
        "worker_storage_key" => WorkerStorageIdentity.queue_key,
        "source_snapshot_id" => snapshot.id,
        "source_snapshot_sha" => snapshot.source_sha,
        "source_snapshot_ref" => snapshot.source_ref,
        "prepare_cache_status" => prepare_cache_details["status"],
        "checkout_path" => path.to_s,
        "recorded_at" => Time.current.iso8601
      }.compact
    ))
  end

  def record_run_source_snapshot!(snapshot)
    current_run = Thread.current[:syrus_current_run] || @step.latest_run
    return unless current_run

    current_run.update_columns(
      head_sha: snapshot.source_sha,
      updated_at: Time.current
    )
  end

  class PrepareCache
    attr_reader :workflow, :step, :snapshot, :plan, :worker_storage_key, :prepare_fingerprint

    def initialize(workflow:, step:, snapshot:, plan:, worker_storage_key:)
      @workflow = workflow
      @step = step
      @snapshot = snapshot
      @plan = plan
      @worker_storage_key = worker_storage_key
      @prepare_fingerprint = fingerprint_for(plan)
    end

    def with_lock
      FileUtils.mkdir_p(lock_path.dirname)
      File.open(lock_path, File::CREAT | File::RDWR) do |lock_file|
        lock_file.flock(File::LOCK_EX)
        yield
      ensure
        lock_file&.flock(File::LOCK_UN)
      end
    end

    def hit?
      marker_path.file? && marker_matches?
    end

    def store_from!(checkout_path)
      temporary_path = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      FileUtils.rm_rf(temporary_path.to_s)
      FileUtils.mkdir_p(path.dirname)
      FileUtils.mkdir_p(temporary_path)
      FileUtils.cp_r(Pathname.new(checkout_path).children.map(&:to_s), temporary_path.to_s, preserve: true)
      FileUtils.rm_rf(path.to_s)
      FileUtils.mv(temporary_path.to_s, path.to_s)
    ensure
      FileUtils.rm_rf(temporary_path.to_s) if temporary_path && temporary_path.exist?
    end

    def path
      WorkflowWorkspace.path_for(workflow).join(
        PREPARE_CACHE_ROOT,
        sanitized_worker_storage_key,
        workflow.id.to_s,
        snapshot.source_sha,
        prepare_fingerprint
      )
    end

    def marker_path
      path.join(PREPARED_MARKER)
    end

    def cache_key
      [
        worker_storage_key,
        workflow.id,
        snapshot.source_sha,
        prepare_fingerprint
      ].join(":")
    end

    def short_cache_key
      Digest::SHA256.hexdigest(cache_key).first(12)
    end

    def details(status)
      {
        "status" => status,
        "worker_storage_key" => worker_storage_key,
        "workflow_id" => workflow.id,
        "source_snapshot_id" => snapshot.id,
        "source_snapshot_sha" => snapshot.source_sha,
        "prepare_fingerprint" => prepare_fingerprint,
        "cache_key" => cache_key,
        "cache_path" => path.to_s,
        "prepare_source" => plan.source,
        "command_count" => plan.commands.size,
        "#{status}_at" => Time.current.iso8601
      }
    end

    private

    def marker_matches?
      JSON.parse(marker_path.read).slice(
        "worker_storage_key",
        "workflow_id",
        "source_sha",
        "prepare_fingerprint"
      ) == {
        "worker_storage_key" => worker_storage_key,
        "workflow_id" => workflow.id,
        "source_sha" => snapshot.source_sha,
        "prepare_fingerprint" => prepare_fingerprint
      }
    rescue JSON::ParserError
      false
    end

    def fingerprint_for(plan)
      Digest::SHA256.hexdigest(JSON.generate(
        "source" => plan.source,
        "note" => plan.note,
        "guessed" => plan.guessed?,
        "commands" => plan.commands
      ))
    end

    def sanitized_worker_storage_key
      WorkerStorageIdentity.sanitize(worker_storage_key) || "unknown-worker"
    end

    def lock_path
      WorkflowWorkspace.path_for(workflow).join(
        PREPARE_CACHE_LOCK_ROOT,
        "#{Digest::SHA256.hexdigest(cache_key)}.lock"
      )
    end
  end
end
