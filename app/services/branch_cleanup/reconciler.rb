module BranchCleanup
  class Reconciler
    Result = Data.define(:status, :reason) do
      def deleted? = status == :deleted
    end

    def initialize(repository:, user:, branch_name:, recorded_sha: nil, owner_job: nil, dry_run: false)
      @repository = repository
      @user = user
      @branch_name = branch_name.to_s
      @recorded_sha = recorded_sha.presence
      @owner_job = owner_job
      @dry_run = dry_run
    end

    def call
      reason = unsafe_reason
      return result(:protected, reason) if reason

      remote_sha = client.branch_head_sha(repository.slug, branch_name)
      return result(:deleted, "remote ref is already missing") if remote_sha.blank?
      if recorded_sha && remote_sha != recorded_sha
        return result(:protected, "remote SHA no longer matches the recorded Syrus SHA")
      end
      return result(:candidate, "safe to delete") if dry_run

      client.delete_branch(repository.slug, branch_name) ? result(:deleted, "deleted") : result(:failed, "GitHub refused branch deletion")
    rescue Octokit::NotFound
      result(:deleted, "remote ref is already missing")
    rescue => e
      result(:failed, "#{e.class}: #{e.message}")
    end

    private

    attr_reader :repository, :user, :branch_name, :recorded_sha, :owner_job, :dry_run

    def unsafe_reason
      return "branch is not in the Syrus namespace" unless branch_name.start_with?("syrus/")
      return "branch is the repository default branch" if branch_name == repository.default_branch
      return "branch belongs to nonterminal work" if live_job_branch?
      return "branch belongs to an active workflow" if active_workflow_branch?
      return "branch belongs to an active merge train" if active_train_branch?
      return "branch is still required by open stacked or dependent work" if required_by_open_work?
      "branch is referenced by an open pull request" if open_pr_ref?
    end

    def live_job_branch?
      Job.where(repository_id: repository.id, branch_name: branch_name).where.not(state: Job::TERMINAL_STATES).exists?
    end

    def active_workflow_branch?
      active_states = Workflow.aasm.states.reject { |state| %i[succeeded failed cancelled blocked].include?(state.name) }.map(&:name)
      active = Workflow.joins(:job).includes(:workflow_artifact_values)
        .where(jobs: { repository_id: repository.id }, state: active_states)
      return true if active.where(jobs: { branch_name: branch_name }).exists?

      active.any? { |workflow| workflow.artifact(WorkflowWorkspace::REQUIRED_BRANCH_ARTIFACT) == branch_name }
    end

    def active_train_branch?
      MergeTrain.active.where(repository_id: repository.id, integration_branch: branch_name).exists?
    end

    def required_by_open_work?
      return false unless owner_job

      Job.where(parent_job_id: owner_job.id).where.not(state: Job::TERMINAL_STATES).exists? ||
        JobDependency.joins(:job).where(depends_on_job_id: owner_job.id).where.not(jobs: { state: Job::TERMINAL_STATES }).exists?
    end

    def open_pr_ref?
      client.list_open_pull_requests(repository.slug).any? do |pr|
        pr.head&.ref == branch_name || pr.base&.ref == branch_name
      end
    end

    def client
      @client ||= GithubClient.for(repository: repository, user: user)
    end

    def result(status, reason)
      Rails.logger.public_send(status == :failed ? :warn : :info,
        { event: "branch_cleanup", repository: repository.slug, branch: branch_name, status: status, reason: reason }.to_json)
      Result.new(status:, reason:)
    end
  end
end
