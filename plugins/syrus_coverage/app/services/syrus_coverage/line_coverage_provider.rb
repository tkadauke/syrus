module SyrusCoverage
  # The plugin's answers to core's per-line coverage questions; see
  # Syrus::Plugin::LineCoverageProvider.
  class LineCoverageProvider
    def self.diff_line_statuses(job:, version:, files:)
      SyrusCoverage::DiffAnnotationsPayload.build(job: job, version: version, files: files)
    end

    def self.latest_default_branch_files(repository:)
      snapshot = SyrusCoverage::Snapshot
        .where(repository: repository)
        .for_project(SyrusCoverage.root_project_id)
        .on_branch(repository.default_branch)
        .order(created_at: :desc)
        .first
      return nil unless snapshot

      { sha: snapshot.sha, recorded_at: snapshot.created_at, files: snapshot.data || {} }
    end

    def self.agent_context_lines(run:, workspace_path:, repository:)
      SyrusCoverage::AgentContext.new(run: run, workspace_path: workspace_path, repository: repository).lines_for_prompt
    end
  end
end
