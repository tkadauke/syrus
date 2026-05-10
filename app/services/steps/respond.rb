module Steps
  # First step of PrFeedback workflow. Agent receives the new
  # review comments + the original issue/diff context (via
  # Prompts::PrFeedback), addresses each piece of feedback,
  # commits to the existing branch.
  #
  # Cross-workflow boundary: NO --resume from the prior Initial
  # workflow's session. The prompt carries the context the agent
  # needs.
  class Respond < Base
    def call
      perform_agentic_change_step(
        log_message: "invoking agent for respond step (workflow ##{workflow.id}, pr_comment)",
        commit_message: "Syrus respond step (will be rewritten by summarize_amend)"
      ) do
        run.update!(prompt: compose_prompt) if run.prompt.blank?
      end
    end

    private

    def compose_prompt
      comments = comments_for_agent
      cutoff = parse_cutoff(workflow.artifact("feedback_cutoff"))
      issue = job.issue? ? GithubClient.for(repository: repository, user: job.user).fetch_issue(repository.slug, job.issue_number) : job.synthetic_issue

      prompt = Prompts::PrFeedback.new(
        issue: issue,
        comments: hydrate_comments(comments),
        cutoff: cutoff,
        prior_summaries: prior_pr_comment_summaries,
        recent_commits: recent_branch_commits
      ).to_s

      return prompt unless run.iteration > 1

      [
        prompt,
        Prompts::GradeFailureFeedback.new(
          iterations: workflow.artifacts.fetch("iterations", [])
        ).to_s
      ].join("\n\n")
    end

    def parse_cutoff(raw)
      return nil if raw.blank?
      Time.zone.parse(raw.to_s)
    rescue ArgumentError
      nil
    end

    # Pull agent_summary strings off every prior pr_comment Workflow
    # on this Job that produced one, in chronological order. The
    # current workflow is excluded — the summary it will produce is
    # not relevant to this Step's own prompt. Skips Workflows that
    # never reached summarize_amend (no agent_summary on any Run).
    def prior_pr_comment_summaries
      prior_workflows = job.workflows
                           .where(trigger_kind: "pr_comment")
                           .where("id < ?", workflow.id)
                           .order(:created_at)
                           .to_a
      prior_workflows.map { |wf| summary_for(wf) }.compact
    end

    def summary_for(wf)
      wf.steps
        .where(kind: "summarize_amend")
        .order(:position)
        .each do |step|
          step.runs.order(:created_at).each do |r|
            return r.agent_summary if r.agent_summary.present?
          end
        end
      nil
    end

    # Last N commit subjects on the working branch, newest first.
    # Best-effort — workspace setup may not have happened yet, the
    # git log may fail, etc. — return [] rather than crashing the
    # prompt build.
    def recent_branch_commits(limit: 10)
      workspace.setup
      raw = GitRunner.new.run("log",
        "--no-merges",
        "-n", limit.to_s,
        "--format=%H%x09%s",
        "HEAD",
        chdir: workspace.path.to_s)
      raw.each_line.map do |line|
        sha, subject = line.chomp.split("\t", 2)
        { sha: sha, subject: subject }
      end
    rescue StandardError => e
      log("[respond] could not read commit history for prompt: #{e.class}: #{e.message}")
      []
    end

    def comments_for_agent
      applied_ids = Array(workflow.artifact("applied_suggestions")).map { |s| s["comment_id"] }.compact
      comments = Array(workflow.artifact("pr_comments")).filter_map do |comment|
        copy = comment.dup
        copy["body"] = strip_suggestion_blocks(copy["body"]) if applied_ids.include?(copy["id"])
        copy["body"].present? ? copy : nil
      end

      conflicts = Array(workflow.artifact("suggestion_conflicts"))
      return comments if conflicts.empty?

      comments + [ {
        "author" => "Syrus",
        "body" => "Some GitHub suggested changes could not be applied automatically:\n" +
          conflicts.map { |c| "- #{c['path']}:#{c['start_line']}-#{c['line']} (#{c['reason']})" }.join("\n"),
        "path" => nil,
        "line" => nil,
        "diff_hunk" => nil,
        "created_at" => Time.current.iso8601
      } ]
    end

    # The polling job stashes raw comment data on the workflow
    # artifact when instantiating; rehydrate it into objects that
    # Prompts::PrFeedback expects (responds to #user.login,
    # #body, #path, etc.). Tolerant — anything missing renders
    # as a generic string.
    def hydrate_comments(raw)
      raw.map do |c|
        Struct.new(:user, :body, :path, :line, :diff_hunk, :created_at).new(
          Struct.new(:login).new(c["author"] || "reviewer"),
          c["body"], c["path"], c["line"], c["diff_hunk"], c["created_at"]
        )
      end
    end

    def strip_suggestion_blocks(body)
      body.to_s.gsub(Steps::ApplySuggestions::SUGGESTION_BLOCK, "").strip
    end
  end
end
