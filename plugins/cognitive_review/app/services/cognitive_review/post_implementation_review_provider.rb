module CognitiveReview
  class PostImplementationReviewProvider
    include Syrus::Plugin::PostImplementationReviewProvider

    REVIEW_TRIGGER_KINDS = %w[
      initial
      retry
      pr_comment
      chat_feedback
      manual
      manual_agentic_run
    ].freeze

    def self.review_needed?(job:, trigger_kind:)
      return false unless CognitiveReview.enabled?
      return false unless job&.repository

      REVIEW_TRIGGER_KINDS.include?(trigger_kind.to_s)
    end

    def self.prompt_sections(job:, workflow:, run:)
      [
        memory_context(job),
        diff_context(job: job, workflow: workflow, run: run),
        review_note_policy_context(job: job, workflow: workflow, run: run),
        <<~PROMPT.strip
          Review the final implementation diff for #{job.repository.slug} and submit high-signal Review Notes.

          Produce comment-like review notes only for changed diff ranges that are likely
          to interest the operator. Use Agent Memory when available to choose ranges the
          operator is likely to care about. Prefer no note over filler. The strongest
          notes usually concern design constraints, lifecycle or state-machine choices,
          concurrency or race assumptions, queue behavior, safety boundaries, migrations
          or data concerns, missing verification, tricky tests, subtle UI decisions,
          surprising tradeoffs, or other operator-memory-guided interests.
          A small but architectural change deserves consideration when it introduces
          shared services, workflow adapters, lifecycle or retry/fallback behavior,
          MCP/tool contracts, persisted artifact or provenance choices, or final-diff
          revision resolution paths. Routine test implementation is usually low-signal;
          changes to testing frameworks, shared harnesses, coverage boundaries, or risk
          models are high-signal.

          Explanations should be concise review guidance explaining why the code is the
          way it is, not a generic checklist. Submit your result with submit_review_notes.
          If no ranges deserve attention, call it with an empty notes array. Do not edit files.
        PROMPT
      ].compact_blank
    end

    def self.required_mcp_tools(job:, workflow:, run:)
      [ Tools::SubmitReviewNotesTool.tool_name ]
    end

    def self.memory_context(job)
      context = Prompts::MemoryContext.new(
        user: job&.user,
        repository_ids: [ job&.repository_id ].compact
      ).to_s
      return "Agent Memory context:\n\n#{context}" if context.present?
      return "Agent Memory context: enabled, but no relevant memories were found." if Syrus::Memory.available?

      "Agent Memory context: unavailable; rely on the Job prompt, repository context, and final diff."
    rescue StandardError => e
      Rails.logger.warn("[CognitiveReview::PostImplementationReviewProvider] memory context unavailable: #{e.class}: #{e.message}")
      "Agent Memory context: unavailable; rely on the Job prompt, repository context, and final diff."
    end
    private_class_method :memory_context

    def self.diff_context(job:, workflow:, run:)
      version = diff_review_version(job: job, workflow: workflow, run: run)
      return fallback_diff_context(job) unless version

      file_lines = Array(version.files_snapshot).first(40).map do |file|
        path = file["path"].to_s
        status = file["status"].to_s.presence || "modified"
        additions = file["additions"].to_i
        deletions = file["deletions"].to_i
        "- #{path} (#{status}, +#{additions}/-#{deletions})"
      end
      omitted = Array(version.files_snapshot).size - file_lines.size
      file_lines << "- ... #{omitted} more file(s)" if omitted.positive?

      [
        "Final diff review version:",
        "- Base/head: #{version.base_sha}...#{version.head_sha}",
        "- Changed files:",
        file_lines.presence&.join("\n") || "- (no changed files recorded)",
        "",
        "Inspect exact ranges with `git diff #{version.base_sha}...#{version.head_sha} -- <path>` before submitting notes."
      ].join("\n")
    end
    private_class_method :diff_context

    def self.review_note_policy_context(job:, workflow:, run:)
      return nil unless workflow

      version = diff_review_version(job: job, workflow: workflow, run: run)
      return nil unless version

      changed_files = Array(version&.files_snapshot).filter_map { |file| file["path"].to_s.presence }
      policy = App::ReviewNoteProjects.call(
        workspace_path: WorkflowWorkspace.path_for(workflow),
        changed_files: changed_files
      )
      return nil if policy.empty?

      lines = [ "Repository Review Notes policy from .syrus.yml:" ]
      if policy.criteria.present?
        lines << ""
        lines << "High-signal interests:"
        lines.concat(policy.criteria.map { |entry| "- #{entry}" })
      end
      if policy.low_signal.present?
        lines << ""
        lines << "Low-signal guidance:"
        lines.concat(policy.low_signal.map { |entry| "- #{entry}" })
      end
      if policy.projects.present?
        lines << ""
        lines << "Applicable policy scopes:"
        lines.concat(policy.projects.map { |project| "- #{project.label} (#{project.owner_config_path})" })
      end

      lines.join("\n")
    rescue StandardError => e
      Rails.logger.warn("[CognitiveReview::PostImplementationReviewProvider] review notes policy unavailable: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :review_note_policy_context

    def self.diff_review_version(job:, workflow:, run:)
      DiffReviewVersion.best_match_for(job_id: job&.id, run_id: run&.id, workflow_id: workflow&.id)
    end
    private_class_method :diff_review_version

    def self.fallback_diff_context(job)
      base_ref =
        job&.mergeability_base_ref.presence ||
        job&.target_branch.presence ||
        job&.base_default_branch.presence ||
        job&.repository&.default_branch.presence ||
        "the base branch"

      [
        "Final diff review version: unavailable.",
        "Inspect the workspace diff against #{base_ref} before submitting notes."
      ].join("\n")
    end
    private_class_method :fallback_diff_context
  end
end
