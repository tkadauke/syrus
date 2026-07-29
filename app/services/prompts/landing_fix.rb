module Prompts
  # Prompt for the final agentic pass inside auto-merge. The agent is
  # operating on the exact branch state Syrus is about to grade and
  # merge. Later loop iterations append Prompts::GradeFailureFeedback.
  class LandingFix
    def initialize(issue:, pr_number:, repo_slug:, branch_name:, recent_commits: [], epic: nil, job: nil)
      @issue = issue
      @pr_number = pr_number
      @repo_slug = repo_slug
      @branch_name = branch_name
      @recent_commits = recent_commits || []
      @epic = epic
      @job = job
    end

    def to_s
      sections = [
        context_section,
        issue_section,
        epic_context,
        commits_section,
        directives_section
      ].compact

      [ sections.join("\n\n---\n\n"), GitSafety::TEXT ].join("\n\n")
    end

    private

    def context_section
      <<~SECTION.strip
        This is the final merge-readiness pass for PR `#{@repo_slug}##{@pr_number}` on branch `#{@branch_name}`.

        Syrus is about to run the repository graders and merge this PR if they pass.
      SECTION
    end

    def issue_section
      <<~SECTION.strip
        Original issue: #{@issue.title}

        #{@issue.body.to_s.strip.presence || "(empty)"}
      SECTION
    end

    def epic_context
      Prompts::EpicContext.new(epic: @epic, job: @job).to_s.presence
    end

    def commits_section
      return nil if @recent_commits.empty?

      lines = @recent_commits.map do |commit|
        sha = commit[:sha] || commit["sha"]
        subject = commit[:subject] || commit["subject"]
        "- #{sha.to_s[0, 7]} #{subject}"
      end

      <<~SECTION.strip
        Recent commits on the PR branch (newest first):

        #{lines.join("\n")}
      SECTION
    end

    def directives_section
      [
        "Inspect the current branch for integration problems that could make the final graders fail after the latest rebase or concurrent branch changes.",
        "If prior grader failures are included below, fix those failures directly and keep the change scoped to making the final graders pass.",
        "If there is no concrete problem to fix, make no code changes.",
        "Do not broaden the feature, rewrite unrelated code, or change the repository's grader configuration unless the grader configuration itself is the broken code.",
        "Make commits to the current branch only when you actually change files."
      ].join("\n")
    end
  end
end
