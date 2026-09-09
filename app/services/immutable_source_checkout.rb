require "fileutils"

class ImmutableSourceCheckout
  CHECKOUT_ROOT = ".syrus/immutable-checkouts/steps".freeze

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
    materialize!(snapshot) unless valid_checkout?(snapshot)
    verify_head!(snapshot)
    ensure_exclude_entry
    prepare!(snapshot)
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

    @git.run("init", path.to_s)
    @git.run("remote", "add", "origin", @repository.remote_url, chdir: path.to_s)
    fetch_snapshot!(snapshot)
    @git.run("checkout", "--detach", snapshot.source_sha, chdir: path.to_s)
  rescue GitRunner::GitError => e
    raise_infrastructure!("immutable source checkout failed for #{snapshot.source_ref}@#{snapshot.source_sha}: #{e.message}")
  end

  def fetch_snapshot!(snapshot)
    authenticated_git("git_immutable_source_fetch") do |url|
      @git.run("fetch", "--no-tags", url, source_refspec(snapshot), chdir: path.to_s, env: @env)
    end
    record_origin_head!(snapshot)
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
    return if actual == snapshot.source_sha

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

  def prepare!(snapshot)
    return if prepared?(snapshot)

    plan = RepoPrepPlan.for(path)
    log("[immutable_source_checkout] prepare source: #{plan.source}")
    log("[immutable_source_checkout] prepare note: #{plan.note}") if plan.note
    return record_prepared!(snapshot, plan) if plan.commands.empty?

    plan.commands.each_with_index do |command, index|
      log("[immutable_source_checkout] prepare (#{index + 1}/#{plan.commands.size}) $ #{command}")
      next if run_prepare_command(command)

      if plan.guessed?
        log("[immutable_source_checkout] guessed prepare command failed; continuing with immutable checkout unprepared")
        return
      end

      raise Steps::Base::StepFailed, "immutable source prepare command failed: #{command}"
    end

    record_prepared!(snapshot, plan)
  end

  def prepared?(snapshot)
    prepared_marker.exist? &&
      JSON.parse(prepared_marker.read).slice("source_snapshot_id", "source_sha") == {
        "source_snapshot_id" => snapshot.id,
        "source_sha" => snapshot.source_sha
      }
  rescue JSON::ParserError
    false
  end

  def record_prepared!(snapshot, plan)
    FileUtils.mkdir_p(prepared_marker.dirname)
    prepared_marker.write(JSON.pretty_generate(
      "source_snapshot_id" => snapshot.id,
      "source_sha" => snapshot.source_sha,
      "source_ref" => snapshot.source_ref,
      "prepared_at" => Time.current.iso8601,
      "prepare_source" => plan.source
    ))
  end

  def prepared_marker
    path.join(".syrus", "immutable-source-prepared.json")
  end

  def run_prepare_command(command)
    result = ProcessRunner.new(
      env: prepare_env,
      command: [ "bash", "-c", command ],
      chdir: path,
      timeout: Steps::Prepare::PER_COMMAND_TIMEOUT,
      kind: "prepare",
      run: Thread.current[:syrus_current_run],
      workflow: @workflow,
      on_output_chunk: ->(chunk) { log(chunk.to_s.chomp) }
    ).run

    result.success? && !result.timed_out?
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
end
