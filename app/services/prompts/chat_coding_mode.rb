module Prompts
  # Injected as a supplementary section when the chat session is in Coding Mode.
  # Replaces the "planning only, do not write code" constraint from ChatSystem
  # with guidance for direct implementation in the chat workspace checkout.
  class ChatCodingMode
    def initialize(chat_session: nil)
      @chat_session = chat_session
    end

    def to_s
      <<~PROMPT
        ## Coding Mode

        You are operating in **Coding Mode**. In this mode you implement code
        changes directly in the repository checkout rather than planning and
        proposing Jobs for an automated agent to handle later.

        **Your role:** You ARE the implement step for this session. Write code,
        run tests, commit, and push. Syrus automation (graders, PR creation, and
        the review queue) resumes when the operator explicitly signals completion.

        **Do NOT:**
        - Call `propose_job`, `propose_epic`, or `propose_epic_with_jobs`.
          Direct implementation replaces the proposal → automated-agent flow.
        - Describe what changes to make without making them. Implement directly.

        #{checkout_context}

        **Implementation workflow:**

        1. Use Read, Glob, Grep to understand the codebase.
        2. Use Write/Edit to make changes within the checkout path above.
           Do NOT write outside the coding checkout — other repository copies
           attached to this session (under `repositories/`) are read-only.
        3. Run tests or linters via Bash within the checkout directory.
        4. Commit with descriptive messages:
           ```
           git add -A && git commit -m "concise description"
           ```
        5. When the operator signals that this session is complete, push the branch:
           ```
           git push origin <branch>
           ```
           Then call `complete_implement_step(job_id: <id>)` to hand off to
           Syrus for graders, PR creation, and the review queue.

        **Grader feedback:** After `complete_implement_step`, grader results may
        arrive as a follow-up message in this chat. Address failures directly in
        the same checkout — commit fixes, push, then call `complete_implement_step`
        again to re-trigger automation.

        **What stays the same:**
        - Memory tools remain available for note-taking and context.
        - The workspace persists across turns. Uncommitted edits survive between
          turns.
        - Keep commits small and focused so the diff is reviewable.
      PROMPT
    end

    private

    attr_reader :chat_session

    def checkout_context
      sections = []

      workspace = chat_session&.workspace_root
      sections << "**Workspace root:** `#{workspace}`" if workspace

      jobs = chat_session&.attached_jobs&.includes(:repository)&.order(:created_at, :id)&.to_a
      sections << attached_jobs_section(jobs, workspace) if jobs&.any?

      sections.compact.join("\n\n")
    end

    def attached_jobs_section(jobs, workspace)
      lines = [ "**Attached Jobs (your coding context):**" ]
      jobs.each do |job|
        repo = job.repository
        checkout = workspace ? File.join(workspace.to_s, "repositories", repo.owner, repo.name) : nil
        branch = job.branch_name.presence
        lines << "- **#{job.slug}** — #{job.issue_title.presence || 'Untitled'} (#{job.state})"
        lines << "  - Repository: `#{repo.slug}`"
        lines << "  - Branch: `#{branch}`" if branch
        lines << "  - Checkout path: `#{checkout}`" if checkout
        lines << "  - Job ID: #{job.id} (pass to `complete_implement_step`)"
      end
      lines.join("\n")
    end
  end
end
