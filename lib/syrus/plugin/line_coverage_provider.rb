module Syrus
  module Plugin
    # Interface for a plugin that holds per-line coverage evidence for a
    # repository, so core surfaces that merely *display or reason about* it do
    # not have to own the analysis.
    #
    #   .diff_line_statuses(job:, version:, files:)
    #     => { "path.rb" => { "12" => "covered" | "uncovered" | "not_executable" } }
    #        Status of the changed lines of a reviewed diff. `version` may be nil.
    #
    #   .latest_default_branch_files(repository:)
    #     => { sha: String, recorded_at: Time, files: { "path.rb" => { "lines_pct" => Float, ... } } } or nil
    #        Newest repository-wide snapshot of the default branch.
    #
    #   .agent_context_lines(run:, workspace_path:, repository:)
    #     => Array<String>  lines for the agent environment snapshot, or [].
    #
    # Every method is optional; core asks through App::LineCoverageSource, which
    # treats a missing method, a declining provider, or a raising provider as
    # "no evidence".
    module LineCoverageProvider
      def self.included(base) = base.extend(self)
    end
  end
end
