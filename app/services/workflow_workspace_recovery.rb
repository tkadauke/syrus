class WorkflowWorkspaceRecovery
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
      run = machine.active_run
      return machine.success(nil, "workspace reconstructed; no active Run needed reconciliation") unless run
      return machine.retry_required("active #{run.step.kind} Run may mutate state and cannot be replayed safely") if run.running? && run.step.kind != "grader_collect"

      if run.step.kind == "grader_collect" && run.running?
        run.update_columns(state: "queued", started_at: nil, finished_at: nil, updated_at: Time.current)
        run.step.update_columns(state: "queued", started_at: nil, finished_at: nil, updated_at: Time.current)
      end
      RunJob.perform_later(run.id)
      machine.success(run, "workspace reconstructed and #{run.step.kind} resumed")
    end
  end

  class RetryRequired < State
    def call = machine.failure
  end

  attr_reader :workflow, :workspace, :git, :candidate
  attr_writer :candidate

  def self.call(...) = new(...).call

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
    @active_run ||= workflow.runs.active.order(:created_at, :id).last
  end

  def durable_candidates
    candidates = []
    WorkflowSourceSnapshots.current_for(workflow)&.then do |snapshot|
      candidates << Candidate.new(ref: snapshot.source_ref, sha: snapshot.source_sha,
        published_at: snapshot.published_at, id: snapshot.id, source: "source_snapshot") if remote_sha(snapshot.source_ref) == snapshot.source_sha
    end
    RunCheckpoint.published.where(workflow_id: workflow.id).recent.each do |checkpoint|
      next unless remote_sha(checkpoint.remote_ref) == checkpoint.commit_sha

      candidates << Candidate.new(ref: checkpoint.remote_ref, sha: checkpoint.commit_sha,
        published_at: checkpoint.published_at, id: checkpoint.id, source: "run_checkpoint")
    end
    branch = workflow.job.branch_name.presence
    if branch && (sha = remote_sha("refs/heads/#{branch}"))
      mutation_heads = workflow.runs.joins(:step)
        .where(steps: { kind: RunCheckpointPublisher::MUTATION_STEP_KINDS }, state: "succeeded")
        .where.not(head_sha: [ nil, "" ]).pluck(:head_sha)
      if mutation_heads.empty? || mutation_heads.include?(sha)
        candidates << Candidate.new(ref: "refs/heads/#{branch}", sha: sha,
          published_at: workflow.created_at, id: 0, source: "durable_branch")
      end
    end
    candidates
  end

  private

  def remote_sha(ref)
    output = GithubAuthenticatedGit.run(
      repository: workflow.job.repository, user: workflow.job.user, git: git,
      operation_type: "git_workspace_recovery_ls_remote"
    ) { |url| git.run("ls-remote", url, ref, chdir: workspace.path.dirname.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" }) }
    output.to_s.lines.first.to_s.split(/\s+/).first.presence
  rescue GitRunner::GitError
    nil
  end
end
