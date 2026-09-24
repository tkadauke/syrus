require "fileutils"
require "digest"
require "json"
require "open3"
require "securerandom"

class ImmutableSourceCheckout
  CHECKOUT_ROOT = ".syrus/immutable-checkouts/steps".freeze
  PREPARE_CACHE_ROOT = ".syrus/immutable-checkouts/prepare-cache".freeze
  PREPARE_CACHE_LOCK_ROOT = ".syrus/immutable-checkouts/prepare-cache-locks".freeze
  PREPARED_MARKER = ".syrus/immutable-source-prepared.json".freeze
  PREPARED_ARCHIVE_CONTENT_TYPE = PreparedWorkspaceArchive::CONTENT_TYPE
  PREPARED_ARCHIVE_MAX_BYTES = PreparedWorkspaceArchive::MAX_BYTES

  attr_reader :path

  def self.path_for(step)
    WorkflowWorkspace.path_for(step.workflow).join(CHECKOUT_ROOT, step.id.to_s)
  end

  def initialize(step, git: nil, log: nil)
    @step = step
    @workflow = step.workflow
    @job = @workflow.job
    @repository = @job.repository
    @git = git || GitRunner.new(workflow: @workflow)
    @log = log
    @path = self.class.path_for(step)
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def setup
    raise_infrastructure!("immutable source checkout is disabled for #{@repository.slug}") unless enabled_for_step?

    snapshot = source_snapshot
    log("[immutable_source_checkout] verifying source snapshot ##{snapshot.id} #{snapshot.source_ref}@#{snapshot.source_sha.first(7)}")
    restored_from_prepare_cache = false
    restored_from_archive = false
    unless valid_checkout?(snapshot)
      restored_from_prepare_cache = restore_prepare_cache_checkout!(snapshot)
      restored_from_archive = restore_prepared_archive_checkout!(snapshot) unless restored_from_prepare_cache
      materialize!(snapshot) unless restored_from_prepare_cache || restored_from_archive || valid_checkout?(snapshot)
    end
    verify_head!(snapshot)
    ensure_base_ref!
    ensure_exclude_entry
    prepare_cache = build_prepare_cache(snapshot)
    if restored_from_prepare_cache && prepare_cache.hit?
      record_prepare_cache!(prepare_cache, "hit")
      log("[immutable_source_checkout] prepare cache hit: #{prepare_cache.short_cache_key}")
    elsif restored_from_archive && prepared_archive_matches_prepare_cache?(snapshot, prepare_cache)
      finalize_restored_prepared_archive!(snapshot, prepare_cache)
    else
      prepare_with_cache!(snapshot, prepare_cache)
    end
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

  def ensure_base_ref!
    return if git_ref_exists?(base_ref)

    remote, branch = remote_tracking_ref_parts(base_ref)
    log("[immutable_source_checkout] fetching base ref #{base_ref}")
    ensure_remote!(remote)
    authenticated_git_for(remote_repository(remote), "git_immutable_source_base_fetch") do |url|
      @git.run(
        "fetch", "--no-tags", url,
        "+refs/heads/#{branch}:refs/remotes/#{remote}/#{branch}",
        chdir: path.to_s,
        env: @env
      )
    end
    return if git_ref_exists?(base_ref)

    raise_infrastructure!("immutable source checkout missing base ref #{base_ref}")
  rescue GitRunner::GitError => e
    raise_infrastructure!("immutable source checkout failed to fetch base ref #{base_ref}: #{e.message}")
  end

  def git_ref_exists?(ref)
    @git.run("rev-parse", "--verify", "--quiet", ref, chdir: path.to_s)
    true
  rescue GitRunner::GitError
    false
  end

  def remote_tracking_ref_parts(ref)
    remote, branch = ref.to_s.split("/", 2)
    if remote.blank? || branch.blank?
      raise_infrastructure!("immutable source checkout cannot determine base ref #{ref}")
    end

    [ remote, branch ]
  end

  def ensure_remote!(remote)
    @git.run("remote", "get-url", remote, chdir: path.to_s)
  rescue GitRunner::GitError
    @git.run("remote", "add", remote, remote_repository(remote).remote_url, chdir: path.to_s)
  end

  def authenticated_git(operation_type, &block)
    authenticated_git_for(@repository, operation_type, &block)
  end

  def authenticated_git_for(repository, operation_type, &block)
    GithubAuthenticatedGit.run(
      repository: repository,
      user: @job.user,
      git: @git,
      operation_type: operation_type,
      log: @log,
      &block
    )
  end

  def remote_repository(remote)
    remote == "upstream" ? @job.base_repository : @repository
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
        ensure_base_ref!
        ensure_exclude_entry
        record_prepare_cache!(prepare_cache, "hit")
        log("[immutable_source_checkout] prepare cache hit: #{prepare_cache.short_cache_key}")
        return
      end

      if restore_prepared_archive!(snapshot, prepare_cache)
        record_prepare_cache!(prepare_cache, "archive_hit")
        log("[immutable_source_checkout] prepare archive hit: #{prepare_cache.short_cache_key}")
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
    publish_prepared_archive!(snapshot, prepare_cache)
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
        Steps::Prepare.prep_extra_env(scope: PrepareScope.for_workflow(@workflow), workspace_path: path)
      )
    )
  end

  def log(message)
    @log&.call(message, kind: "system")
  end

  def raise_infrastructure!(message)
    raise WorkflowSourceSnapshots::InfrastructureStateError, message
  end

  def restore_prepared_archive!(snapshot, prepare_cache)
    attachment = snapshot.prepared_workspace_archive
    return false unless attachment.attached?
    return false unless prepared_archive_metadata_matches?(attachment.blob.metadata, snapshot, prepare_cache)

    archive_path = temporary_archive_path("restore")
    File.open(archive_path, "wb") do |file|
      attachment.download { |chunk| file.write(chunk) }
    end

    FileUtils.rm_rf(path.to_s)
    FileUtils.mkdir_p(path)
    run_tar!("tar", "-xzf", archive_path.to_s, "-C", path.to_s)
    verify_head!(snapshot)
    ensure_base_ref!
    ensure_exclude_entry
    raise "prepared archive is missing declared package binaries" unless prepared_checkout_complete?(path)

    record_prepared!(snapshot, prepare_cache.plan, prepare_cache)
    prepare_cache.store_from!(path)
    true
  rescue StandardError => e
    log("[immutable_source_checkout] prepared archive restore failed; falling back to local prepare: #{e.class}: #{e.message}")
    FileUtils.rm_rf(path.to_s)
    materialize!(snapshot)
    verify_head!(snapshot)
    ensure_base_ref!
    ensure_exclude_entry
    false
  ensure
    FileUtils.rm_f(archive_path.to_s) if archive_path
  end

  def restore_prepare_cache_checkout!(snapshot)
    cache_parent = WorkflowWorkspace.path_for(@workflow).join(
      PREPARE_CACHE_ROOT,
      sanitized_worker_storage_key,
      @workflow.id.to_s,
      snapshot.source_sha
    )
    return false unless cache_parent.directory?

    marker_path = Dir
      .glob(cache_parent.join("*", PREPARED_MARKER).to_s, File::FNM_DOTMATCH)
      .lazy
      .map { |candidate| Pathname.new(candidate) }
      .find { |marker| prepared_marker_snapshot_metadata_matches?(marker, snapshot) }
    return false unless marker_path

    FileUtils.rm_rf(path.to_s)
    FileUtils.mkdir_p(path)
    copy_tree!(marker_path.dirname.dirname, path)
    verify_head!(snapshot)
    ensure_base_ref!
    ensure_exclude_entry
    log("[immutable_source_checkout] restored checkout from local prepare cache before fetching source snapshot")
    true
  rescue StandardError => e
    log("[immutable_source_checkout] local prepare cache restore failed; falling back to prepared archive/source fetch: #{e.class}: #{e.message}")
    FileUtils.rm_rf(path.to_s)
    false
  end

  def restore_prepared_archive_checkout!(snapshot)
    attachment = snapshot.prepared_workspace_archive
    return false unless attachment.attached?
    return false unless prepared_archive_snapshot_metadata_matches?(attachment.blob.metadata, snapshot)

    archive_path = temporary_archive_path("checkout-restore")
    File.open(archive_path, "wb") do |file|
      attachment.download { |chunk| file.write(chunk) }
    end

    FileUtils.rm_rf(path.to_s)
    FileUtils.mkdir_p(path)
    run_tar!("tar", "-xzf", archive_path.to_s, "-C", path.to_s)
    verify_head!(snapshot)
    ensure_base_ref!
    ensure_exclude_entry
    raise "prepared archive is missing declared package binaries" unless prepared_checkout_complete?(path)

    log("[immutable_source_checkout] restored checkout from prepared archive before fetching source snapshot")
    true
  rescue StandardError => e
    log("[immutable_source_checkout] prepared archive checkout restore failed; falling back to source fetch: #{e.class}: #{e.message}")
    FileUtils.rm_rf(path.to_s)
    false
  ensure
    FileUtils.rm_f(archive_path.to_s) if archive_path
  end

  def finalize_restored_prepared_archive!(snapshot, prepare_cache)
    record_prepared!(snapshot, prepare_cache.plan, prepare_cache)
    prepare_cache.store_from!(path)
    record_prepare_cache!(prepare_cache, "archive_hit")
    log("[immutable_source_checkout] prepare archive hit: #{prepare_cache.short_cache_key}")
  end

  def prepared_archive_matches_prepare_cache?(snapshot, prepare_cache)
    prepared_archive_metadata_matches?(snapshot.prepared_workspace_archive.blob.metadata, snapshot, prepare_cache)
  end

  def publish_prepared_archive!(snapshot, prepare_cache)
    PreparedWorkspaceArchive.publish!(
      workflow: @workflow,
      snapshot: snapshot,
      step: @step,
      path: path,
      plan: prepare_cache.plan,
      log: ->(message, **_kwargs) { log("[immutable_source_checkout] #{message}") }
    )
  end

  def prepared_archive_metadata_matches?(metadata, snapshot, prepare_cache)
    metadata.to_h.slice(
      "workflow_id",
      "source_snapshot_id",
      "source_sha",
      "prepare_fingerprint"
    ) == prepared_archive_metadata(snapshot, prepare_cache).slice(
      "workflow_id",
      "source_snapshot_id",
      "source_sha",
      "prepare_fingerprint"
    )
  end

  def prepared_archive_snapshot_metadata_matches?(metadata, snapshot)
    metadata.to_h.slice(
      "workflow_id",
      "source_snapshot_id",
      "source_sha"
    ) == {
      "workflow_id" => @workflow.id,
      "source_snapshot_id" => snapshot.id,
      "source_sha" => snapshot.source_sha
    }
  end

  def prepared_marker_snapshot_metadata_matches?(marker_path, snapshot)
    JSON.parse(marker_path.read).slice(
      "worker_storage_key",
      "workflow_id",
      "source_sha"
    ) == {
      "worker_storage_key" => WorkerStorageIdentity.queue_key,
      "workflow_id" => @workflow.id,
      "source_sha" => snapshot.source_sha
    } && prepared_checkout_complete?(marker_path.dirname.dirname)
  rescue Errno::ENOENT, JSON::ParserError
    false
  end

  def prepared_checkout_complete?(checkout_path)
    NodePackageBinValidator.complete?(checkout_path)
  end

  def sanitized_worker_storage_key
    WorkerStorageIdentity.sanitize(WorkerStorageIdentity.queue_key) || "unknown-worker"
  end

  def prepared_archive_metadata(snapshot, prepare_cache)
    PreparedWorkspaceArchive.metadata(workflow: @workflow, snapshot: snapshot, plan: prepare_cache.plan)
  end

  def temporary_archive_path(prefix)
    WorkflowWorkspace.path_for(@workflow).join(
      ".syrus",
      "immutable-checkouts",
      "archives",
      "#{prefix}-#{@step.id}-#{Process.pid}-#{SecureRandom.hex(6)}.tar.gz"
    ).tap { |archive_path| FileUtils.mkdir_p(archive_path.dirname) }
  end

  def run_tar!(*args)
    _stdout, stderr, status = Open3.capture3(*args)
    raise "tar failed: #{stderr.presence || status.exitstatus}" unless status.success?
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

  class NodePackageBinValidator
    def self.complete?(checkout_path)
      new(checkout_path).complete?
    end

    def initialize(checkout_path)
      @checkout_path = Pathname.new(checkout_path)
    end

    def complete?
      missing_declared_binaries.empty?
    end

    private

    attr_reader :checkout_path

    def missing_declared_binaries
      return [] unless checkout_path.join("package-lock.json").file?
      return [ "node_modules/.package-lock.json" ] unless installed_lock_path.file?

      packages = JSON.parse(installed_lock_path.read).fetch("packages", {})
      packages.each_with_object([]) do |(package_path, package_details), missing|
        next unless package_path.start_with?("node_modules/")
        next unless package_details.is_a?(Hash)

        bin_names(package_path, package_details["bin"]).each do |bin_name|
          bin_path = checkout_path.join("node_modules", ".bin", bin_name)
          missing << bin_name unless bin_path.file? || bin_path.symlink?
        end
      end.uniq
    rescue JSON::ParserError
      []
    end

    def installed_lock_path
      checkout_path.join("node_modules", ".package-lock.json")
    end

    def bin_names(package_path, bin)
      case bin
      when Hash
        bin.keys.map(&:to_s).reject(&:blank?)
      when String
        [ package_path.split("/").last.to_s ].reject(&:blank?)
      else
        []
      end
    end
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
      marker_path.file? && marker_matches? && prepared_checkout_complete?
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

    def prepared_checkout_complete?
      NodePackageBinValidator.complete?(path)
    end

    def fingerprint_for(plan)
      PreparedWorkspaceArchive.prepare_fingerprint_for(plan)
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
