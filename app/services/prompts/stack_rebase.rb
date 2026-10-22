module Prompts
  class StackRebase
    SKILL_FILE = Rails.root.join(".claude/skills/rebase/SKILL.md").freeze

    def initialize(repo_slug:, stack_entries:)
      @repo_slug = repo_slug
      @stack_entries = stack_entries
    end

    def to_s
      pending_branches = @stack_entries.to_set { |entry| entry.fetch("branch_name") }
      rows = @stack_entries.map.with_index(1) do |entry, index|
        pr = entry["pr_number"].present? ? "PR ##{entry["pr_number"]}" : "no PR number"
        base = entry.fetch("base_branch")
        base_ref = pending_branches.include?(base) ? base : "origin/#{base}"
        "#{index}. #{::App::Presentation.job_slug(entry["job_id"])}: `#{entry["branch_name"]}` onto `#{base_ref}` (#{pr})"
      end.join("\n")

      context = <<~CONTEXT.strip
        This is a **stack rebase** run for `#{@repo_slug}`. Rebase the following branches in order, root first:

        #{rows}

        Fetch each listed branch, rebase it onto its listed base, resolve conflicts, and continue through the stack before stopping. Leave every listed branch as a local branch with the rebased HEAD; Syrus will force-push them after this run.
      CONTEXT

      SkillLoader.render(SKILL_FILE, context)
    end
  end
end
