class WorkflowWorkspaceRecovery
  class_attribute :simulation_runner, instance_accessor: false, default: nil

  Result = Data.define(:status, :workflow, :run, :message) do
    def recovered? = status == "recovered"
    def retry_required? = status == "retry_required"
  end

  Candidate = Data.define(:ref, :sha, :published_at, :id, :source)

  class State
    def self.for(name)
      {
        inspect: Inspect,
        reconstruct: Reconstruct,
        resume: Resume,
        retry_required: RetryRequired
      }.fetch(name)
    end

    def initialize(machine) = @machine = machine
    private attr_reader :machine
  end

  class Inspect < State
    def call
      candidate = machine.durable_candidates.max_by { |entry| [ entry.published_at, entry.id ] }
      return machine.transition(:retry_required, "no durable source snapshot, branch head, or agent checkpoint is available") unless candidate

      machine.candidate = candidate
      machine.transition(:reconstruct)
    end
  end

  class Reconstruct < State
    def call
      machine.workspace.reconstruct_from!(machine.candidate.ref)
      actual = machine.git.run("rev-parse", "HEAD", chdir: machine.workspace.path.to_s).strip
      return machine.transition(:retry_required, "reconstructed HEAD #{actual} did not match durable #{machine.candidate.sha}") unless actual == machine.candidate.sha

      WorkflowWorkspaceLifecycle.record_identity!(
        machine.workflow,
        hostname: SyrusVersion.hostname,
        storage_key: WorkerStorageIdentity.queue_key,
        actor: "workspace_recovery"
      )
      machine.transition(:resume)
    rescue StandardError => e
      machine.transition(:retry_required, "#{e.class}: #{e.message}")
    end
  end

  class Resume < State
    def call
      unsafe_run = machine.active_runs.detect do |run|
        run.running? && !run.step.kind.in?(%w[grader grader_collect])
      end
      if unsafe_run
        return machine.retry_required("active #{unsafe_run.step.kind} Run may mutate state and cannot be replayed safely")
      end

      grader_runs = machine.active_runs.select { |run| run.step.kind == "grader" }
      grader_runs.each { |run| machine.requeue!(run) }

      control_run = machine.active_runs.reject { |run| run.step.kind == "grader" }.last
      machine.requeue!(control_run) if control_run

      resumed = grader_runs + Array(control_run)
      return machine.success(nil, "workspace reconstructed; no active Run needed reconciliation") if resumed.empty?

      machine.success(control_run || grader_runs.last,
        "workspace reconstructed and #{resumed.size} stranded Run#{'s' unless resumed.one?} resumed")
    end
  end

  class RetryRequired < State
    def call = machine.failure
  end

  attr_reader :workflow, :workspace, :git, :candidate
  attr_writer :candidate

  def self.call(...)
    return simulation_runner.call(...) if simulation_runner

    new(...).call
  end

  def initialize(workflow:, workspace: nil, git: nil)
    @workflow = workflow
    @git = git || GitRunner.new(workflow: workflow)
    @workspace = workspace || WorkflowWorkspace.new(workflow, git: @git)
  end

  def call
    @state = :inspect
    loop do
      result = State.for(@state).new(self).call
      return result if result.is_a?(Result)
    end
  end

  def transition(state, message = nil)
    @state = state
    @failure_message = message if message
    nil
  end

  def success(run, message)
    Result.new(status: "recovered", workflow: workflow, run: run, message: message)
  end

  def retry_required(message)
    @failure_message = message
    failure
  end

  def failure
    Result.new(status: "retry_required", workflow: workflow, run: active_run, message: @failure_message)
  end

  def active_run
    active_runs.last
  end

  def active_runs
    @active_runs ||= workflow.runs.active.includes(:step).order(:created_at, :id).to_a
  end

  def requeue!(run)
    if run.running?
      now = Time.current
      run.update_columns(state: "queued", started_at: nil, finished_at: nil, updated_at: now)
      run.step.update_columns(state: "queued", started_at: nil, finished_at: nil, updated_at: now)
    end
    retire_pending_queue_jobs!(run)
    run.reenqueue!(ignore_workflow_affinity: true)
  end

  def retire_pending_queue_jobs!(run)
    SolidQueueRunJobPruner.delete_pending_for_run!(run.id)
  end

  def durable_candidates
    candidates = []
    WorkflowSourceSnapshots.current_for(workflow)&.then do |snapshot|
      candidates << Candidate.new(ref: snapshot.source_ref, sha: snapshot.source_sha,
        published_at: snapshot.published_at, id: snapshot.id, source: "source_snapshot") if durable_head?(snapshot.source_ref, snapshot.source_sha)
    end
    RunCheckpoint.published.where(workflow_id: workflow.id).recent.each do |checkpoint|
      next unless durable_head?(checkpoint.remote_ref, checkpoint.commit_sha)

      candidates << Candidate.new(ref: checkpoint.remote_ref, sha: checkpoint.commit_sha,
        published_at: checkpoint.published_at, id: checkpoint.id, source: "run_checkpoint")
    end
    branch = workflow.job.branch_name.presence
    if branch && (sha = remote_sha("refs/heads/#{branch}")) && preserves_latest_mutation?(sha)
      candidates << Candidate.new(ref: "refs/heads/#{branch}", sha: sha,
        published_at: workflow.created_at, id: 0, source: "durable_branch")
    end
    candidates.concat(base_branch_candidates)
    candidates
  end

  private

  # Between a successful prepare and the first mutation, a workflow has no
  # source snapshot, no published checkpoint, and no branch of its own. That is
  # the normal state of a freshly prepared Job, not a corrupt one -- and
  # without a candidate here the ordinary event of "the worker holding a
  # just-prepared workspace was replaced" has no recovery point at all, so the
  # workflow is failed instead of simply re-prepared.
  #
  # The base branch is the same ref prepare checked out, and with no mutation
  # recorded there is nothing of the agent's to lose by going back to it. The
  # guard is `latest_mutation_head` being blank, not merely
  # `preserves_latest_mutation?`: once any mutation has succeeded, the base
  # branch is categorically the wrong answer, because reconstructing from it
  # would silently grade or publish a checkout without the implementation.
  #
  # `id: -1` keeps it the lowest-priority candidate, so a tie with the Job's
  # own branch at the same timestamp resolves to the more specific ref.
  def base_branch_candidates
    return [] if latest_mutation_head.present?

    base = workflow.job.effective_base_branch.presence
    return [] unless base

    ref = "refs/heads/#{base}"
    sha = remote_sha(ref)
    return [] unless sha

    [ Candidate.new(ref: ref, sha: sha, published_at: workflow.created_at, id: -1, source: "base_branch") ]
  end

  def durable_head?(ref, sha)
    remote_sha(ref) == sha && preserves_latest_mutation?(sha)
  end

  # A snapshot or checkpoint from before the latest successful mutation is a
  # valid Git object but not a valid recovery point. Choosing it would silently
  # grade or publish a checkout without the implementation. Be conservative:
  # when the exact mutation head was not published, fail into the fresh
  # workflow retry path instead of attempting to replay mutable work.
  def preserves_latest_mutation?(sha)
    latest_mutation_head.blank? || sha == latest_mutation_head
  end

  def latest_mutation_head
    return @latest_mutation_head if defined?(@latest_mutation_head)

    @latest_mutation_head = workflow.runs.joins(:step)
      .where(steps: { kind: RunCheckpointPublisher::MUTATION_STEP_KINDS }, state: "succeeded")
      .where.not(head_sha: [ nil, "" ])
      .order(Arel.sql("COALESCE(runs.finished_at, runs.created_at) DESC, runs.id DESC"))
      .pick(:head_sha)
  end

  # A best-effort probe: the answer is this ref's remote sha, or nothing.
  #
  # Every caller treats nil as "not a usable recovery point", so any failure to
  # ask is that same answer -- and failing to ask has more causes than a git
  # error. Authenticating the request raises ArgumentError when the Job's user
  # has no usable GitHub token, which escaped this rescue and took the whole
  # repair down with it, turning "I could not reach the remote" into a crashed
  # reconciler pass. Logged rather than silent, because a token that never
  # works is worth seeing in the log even though it is not worth failing on.
  def remote_sha(ref)
    output = GithubAuthenticatedGit.run(
      repository: workflow.job.repository, user: workflow.job.user, git: git,
      operation_type: "git_workspace_recovery_ls_remote"
    ) { |url| git.run("ls-remote", url, ref, chdir: workspace.path.dirname.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" }) }
    output.to_s.lines.first.to_s.split(/\s+/).first.presence
  rescue StandardError => e
    Rails.logger.info(
      "[WorkflowWorkspaceRecovery] could not resolve #{ref} for Workflow ##{workflow.id}: #{e.class}: #{e.message}"
    )
    nil
  end
end
