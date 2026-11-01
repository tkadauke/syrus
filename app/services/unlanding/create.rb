module Unlanding
  class Create
    class Ineligible < StandardError; end

    def self.call!(original:, user: nil, agent_provider: nil)
      new(original:, user:, agent_provider:).call!
    end

    def initialize(original:, user:, agent_provider:)
      @original = original
      @user = user || original.user
      @agent_provider = agent_provider
    end

    def call!
      original.with_lock do
        validate_original!
        shas, base_sha = verified_commits

        rollback = Job.create!(
          user:, repository: original.repository, kind: "direct",
          issue_title: "Rollback #{original.slug}: #{original.title}",
          issue_body: "Compensating rollback for #{original.slug}. The original landing remains closed and unchanged.",
          rollback_of: original, priority: "urgent",
          agent_provider: agent_provider.presence || original.workflow_agent_provider
        )
        workflow = WorkUnits::Launcher.instantiate(
          kind: "unland", job: rollback,
          artifacts: { "unland_commit_shas" => shas, "unland_base_sha" => base_sha },
          agent_provider:, source_type: "unlanding"
        )
        rollback.start_running! if rollback.may_start_running?
        WorkUnits::Launcher.start!(workflow)
        rollback
      end
    end

    private

    attr_reader :original, :user, :agent_provider

    def validate_original!
      unless original.closed? && Job::SUCCESSFUL_CLOSURE_REASONS.include?(original.closure_reason) && original.landed_sha.present?
        raise Ineligible, "only successfully landed Jobs can be unlanded"
      end
      raise Ineligible, "Job was already successfully unlanded" if original.unlanded_by
      active_states = Job::STATES - (Job::TERMINAL_STATES + %w[failed])
      if original.rollback_jobs.where(state: active_states).exists?
        raise Ineligible, "an unland is already active for this Job"
      end
    end

    def verified_commits
      rows = LandedCommit.where(landable: original, kind: "implementation").order(:position, :id)
      raise Ineligible, "landed commits are missing" if rows.empty?

      clone = RepositoryBareClone.new(original.repository)
      clone.sync!(user: user)
      git = GitRunner.new
      base = git.run("rev-parse", "refs/heads/#{original.repository.default_branch}", chdir: clone.path.to_s).strip
      shas = rows.pluck(:sha)
      shas.each do |sha|
        git.run("merge-base", "--is-ancestor", sha, base, chdir: clone.path.to_s)
      rescue GitRunner::GitError
        raise Ineligible, "landed commit #{sha} is not safely reachable from current default branch"
      end
      [ shas, base ]
    rescue GitRunner::GitError => e
      raise Ineligible, "landed commits could not be verified: #{e.message}"
    end
  end
end
