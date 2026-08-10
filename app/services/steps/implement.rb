module Steps
  # First step of Initial / Retry workflows. Spawns claude with
  # Prompts::Implement (issue title + body + issue comments + the
  # standard safety block + a "don't call submit_summary here" nudge).
  # Agent reads the codebase, makes file changes; this handler commits them
  # locally; verifies HEAD shares ancestry with the default branch
  # (orphan-branch defense); records the diff for downstream pages
  # to render.
  #
  # Doesn't push. Doesn't open a PR. Those are pr_open's job.
  class Implement < Base
    MAIN_DIFF_TRIGGER_KINDS = %w[initial retry].freeze
    MAX_MAIN_DIFF_BYTES = 16 * 1024

    def call
      perform_agentic_change_step(
        log_message: "invoking agent for #{target_label} (#{workflow.slug}, step ##{step.id} implement)",
        commit_message: "Syrus implement step (will be rewritten by summarize)"
      ) do
        persist_prompt_if_needed
      end
    end

    private

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id || prior_implement_session_id || super
    end

    def persist_prompt_if_needed
      # Cron Jobs arrive with a pre-rendered prompt (variables
      # already expanded at fire time); skip the GitHub round-trip
      # entirely. Issue Jobs need the issue body to compose
      # Prompts::Implement.
      return if run.prompt.present?

      issue = fetch_issue
      issue_comments = fetch_initial_issue_comments
      job.update!(issue_title: issue.title, issue_body: issue.body) if job.issue?
      workflow.set_artifact!("initial_issue_comments", issue_comments) if job.issue?
      ctx = workflow.artifacts&.dig("replay_context")
      main_ctx = main_branch_context
      run.update!(prompt: implement_prompt(issue: issue, issue_comments: issue_comments, replay_context: ctx, main_branch_context: main_ctx))
    end

    def target_label
      if job.issue?
        "#{repository.slug}##{job.issue_number}"
      elsif job.direct?
        "direct #{job.slug}"
      else
        "scheduled task ##{job.scheduled_task_id}"
      end
    end

    def fetch_initial_issue_comments
      return [] unless job.issue?

      client = GithubClient.for(repository: repository, user: job.user)
      client.issue_comments(repository.slug, job.issue_number)
        .sort_by { |comment| comment.created_at || Time.zone.at(0) }
        .reject { |comment| syrus_authored_noise?(comment) }
        .map { |comment| serialize_issue_comment(comment) }
    end

    def syrus_authored_noise?(comment)
      app_slug = AppSetting.current.github_app_slug.to_s.presence
      return false unless app_slug
      return false unless comment.user&.login == "#{app_slug}[bot]"

      !comment.body.to_s.start_with?("Syrus on behalf of @")
    end

    def serialize_issue_comment(comment)
      {
        "author" => comment.user&.login,
        "body" => comment.body,
        "created_at" => comment.created_at&.iso8601
      }
    end

    def implement_prompt(issue:, issue_comments:, replay_context:, main_branch_context: nil)
      prompt = Prompts::Implement.new(
        issue: issue,
        issue_comments: issue_comments,
        replay_context: replay_context,
        main_branch_context: main_branch_context,
        epic: job.epic,
        job: job,
        user: job.user,
        repository_ids: [ job.repository_id ],
        injected_context: collect_injected_context
      ).to_s
      append_grade_failure_feedback(prompt)
    end

    # Computes commits and diff on the default branch since the Job was
    # filed. Only runs for initial/retry workflows; returns nil (no
    # section injected) when main has not advanced or on git errors.
    def main_branch_context
      return nil unless workflow.trigger_kind.in?(MAIN_DIFF_TRIGGER_KINDS)

      created_at_iso = job.created_at.utc.iso8601
      ref = "origin/#{repository.default_branch}"

      commits = GitRunner.new.run(
        "log", "--oneline", "--since=#{created_at_iso}", ref,
        chdir: workspace.path.to_s
      ).strip
      return nil if commits.blank?

      base_sha = GitRunner.new.run(
        "rev-list", "-1", "--before=#{created_at_iso}", ref,
        chdir: workspace.path.to_s
      ).strip
      return nil if base_sha.blank?

      diff = GitRunner.new.run("diff", "#{base_sha}..#{ref}", chdir: workspace.path.to_s)
      format_main_branch_context(commits: commits, diff: diff)
    rescue GitRunner::GitError => e
      log("[implement] could not compute main branch diff: #{e.message}")
      nil
    end

    def format_main_branch_context(commits:, diff:)
      header = <<~HEADER.strip
        ## Recent changes to main since this Job was filed

        The following commits landed on the default branch after this Job was created.
        Review them before implementing — they may already address this task, contradict
        the planned approach, or introduce dependencies your change must account for.
      HEADER

      if diff.bytesize <= MAX_MAIN_DIFF_BYTES
        "#{header}\n\n#{diff}"
      else
        "#{header}\n\n#{commits}\n\n(The full diff was too large to include; showing the commit list only.)"
      end
    end

    def collect_injected_context
      Syrus::PluginRegistry.providers_for(:prompt_injector)
        .filter_map { |provider| provider.call(repository: repository, job: job) }
    end

    def prior_implement_session_id
      cursor = step.previous_step
      while cursor
        return nil unless cursor.succeeded?

        session_id = cursor.latest_run&.provider_session&.session_id if cursor.kind == "implement"
        return session_id if session_id.present?

        cursor = cursor.previous_step
      end
      nil
    end
  end
end
