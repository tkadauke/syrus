module Prompts
  # Prompt for the agentic reconciliation pass inside an Epic merge train.
  # The integration branch has already been built; this pass reviews the
  # combined tree before normal prepare/grader/coverage/landing gates run.
  class MergeTrainReconcile
    def initialize(epic:, jobs:, repo_slug:, integration_branch:, base_branch:)
      @epic = epic
      @jobs = jobs
      @repo_slug = repo_slug
      @integration_branch = integration_branch
      @base_branch = base_branch
    end

    def to_s
      [
        context_section,
        members_section,
        directives_section,
        GitSafety::TEXT
      ].join("\n\n---\n\n")
    end

    private

    def context_section
      <<~SECTION.strip
        This is an Epic merge-train reconciliation run for `#{@repo_slug}`.

        Syrus has already built the merge-train integration branch `#{@integration_branch}` from base branch `#{@base_branch}`. You are reviewing the integrated result of all member PRs together before Syrus runs prepare, graders, coverage, and landing.

        Epic: #{@epic.slug}: #{@epic.title}

        #{@epic.description.to_s.strip.presence || "(no Epic description)"}
      SECTION
    end

    def members_section
      lines = @jobs.map do |job|
        pr_ref = job.pr_number ? "PR ##{job.pr_number}" : "no PR"
        "- #{job.slug}: #{job.title} (#{pr_ref}, branch `#{job.branch_name}`)"
      end

      <<~SECTION.strip
        Merge-train members:

        #{lines.join("\n")}
      SECTION
    end

    def directives_section
      <<~SECTION.strip
        Task:
        - Inspect the integrated code for cross-Job inconsistencies: mismatched naming, incompatible API shapes, duplicate abstractions, divergent UI patterns, migration conflicts, or shared-surface regressions caused by the combination of member PRs.
        - If there is no concrete inconsistency to fix, make no code changes. A no-diff result is a successful reconciliation.
        - If reconciliation is needed, make only focused edits that reconcile the already-approved member work. Do not broaden the Epic, implement new sibling work, or rewrite unrelated code.
        - Keep all changes on the current integration branch `#{@integration_branch}`. Do not switch to a member Job branch, push, open or edit pull requests, or change landing state.
        - Run the most relevant tests or checks you can for any reconciliation edits. If you make no edits, inspect enough to justify that no tests were necessary.
        - In your final response, include a short `Summary` and `Test evidence` section so the merge-train transcript clearly records what you checked.

        Syrus will commit any uncommitted reconciliation edits after your run and will then continue to the normal prepare, grader, coverage, and mergeability gates.
      SECTION
    end
  end
end
