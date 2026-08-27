module ExternalPrIngestions
  # The `Job.create! + WorkUnits::Launcher.create_and_start!` pair every
  # ingestion path that creates an ordinary reviewable `external_pr` Job
  # needs — `ExternalUnknown`, `SyrusJobExport`'s "no visible source Job"
  # fallback, and `SyrusBranchExport`'s umbrella Job. Exactly what
  # `PollExternalOpenPrsJob#ingest_pr!` did inline before classification
  # existed; pulled out here so those three call sites share one definition
  # instead of drifting.
  class JobFactory
    def self.create!(repository:, pr:, fork_pr:, epic_id: nil)
      new(repository: repository, pr: pr, fork_pr: fork_pr, epic_id: epic_id).create!
    end

    def initialize(repository:, pr:, fork_pr:, epic_id: nil)
      @repository = repository
      @pr = pr
      @fork_pr = fork_pr
      @epic_id = epic_id
    end

    def create!
      job = Job.create!(
        user: repository.user,
        repository: repository,
        kind: "external_pr",
        state: "implemented",
        external_pr_number: pr.number,
        external_pr_author: pr.user&.login,
        external_pr_fork: fork_pr,
        branch_name: pr.head&.ref.to_s.presence,
        issue_title: pr.title,
        epic_id: epic_id
      )
      WorkUnits::Launcher.create_and_start!(kind: "external_pr_ingest", job: job)
      job
    end

    private

    attr_reader :repository, :pr, :fork_pr, :epic_id
  end
end
