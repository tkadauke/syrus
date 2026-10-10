module Steps
  class MergeTrainAgent < Base
    include MergeTrainStep

    TURN_BUDGET = 80
    ACTION_FILE = ".syrus/merge_train_agent.json".freeze
    ARTIFACT_KEY = "merge_train_agent".freeze
    WITHDRAWN_JOB_ID_ARTIFACT = "merge_train_agent_withdrawn_job_id".freeze

    def call
      train = merge_train
      workspace.setup
      checkout_integration_branch!(git, train, chdir: workspace.path.to_s, context: "merge_train_agent")

      run.update!(prompt: compose_prompt(train)) if run.prompt.blank?
      log("invoking agent for merge_train_agent rung (#{workflow.slug}, #{train.integration_branch})")

      base_sha = head_sha
      run_agent(prompt: run.prompt, max_turns: TURN_BUDGET)
      action = read_action!
      commit_agent_changes_excluding_action_file
      assert_branch_history_intact!
      ensure_clean_worktree!

      step_diff = diff_against_sha(base_sha)
      case action.fetch("action")
      when "repair"
        record_repair!(train, base_sha, step_diff, action)
      when "withdraw"
        withdraw_member!(train, action)
      else
        record_no_progress!(action)
      end
    end

    private

    def git
      @git ||= streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_EDITOR" => "true" })
    end

    def compose_prompt(train)
      Prompts::MergeTrainAgent.new(
        train: train,
        workflow: workflow,
        failing_round: latest_failing_round
      ).to_s
    end

    def latest_failing_round
      Array(workflow.artifact(GraderLoopProgress::ARTIFACT_KEY)).max_by { |round| round["iteration"].to_i } || {}
    end

    def read_action!
      path = workspace.path.join(ACTION_FILE)
      raise StepFailed, "merge_train_agent did not write #{ACTION_FILE}" unless path.file?

      payload = JSON.parse(path.read)
      path.delete
      action = payload["action"].to_s
      unless %w[repair withdraw no_progress].include?(action)
        raise StepFailed, "merge_train_agent action must be repair, withdraw, or no_progress"
      end

      payload
    rescue JSON::ParserError => e
      raise StepFailed, "merge_train_agent wrote invalid JSON: #{e.message}"
    end

    def record_repair!(train, base_sha, step_diff, action)
      raise NoChangesProduced, "merge_train_agent recorded repair without repository changes" if step_diff.blank?

      sha = publish_integration_head!(
        git,
        train,
        chdir: workspace.path.to_s,
        context: "merge_train_agent",
        operation_type: "git_merge_train_agent_publish"
      )
      train.update!(integration_sha: sha, state: "grading")
      run.update!(
        base_sha: base_sha,
        head_sha: sha,
        agent_diff: diff_against_default,
        step_agent_diff: step_diff
      )
      workflow.set_artifact!(ARTIFACT_KEY, durable_record(action).merge(
        "result" => "repaired",
        "base_sha" => base_sha,
        "head_sha" => sha,
        "diff_bytes" => step_diff.bytesize
      ))
      publish_run_checkpoint!
      log("merge_train_agent: repaired integration branch #{train.integration_branch} at #{sha.first(9)}", kind: "system")
    end

    def withdraw_member!(train, action)
      member = member_for_action!(train, action)
      workflow.set_artifact!(WITHDRAWN_JOB_ID_ARTIFACT, member.job_id)
      workflow.set_artifact!(ARTIFACT_KEY, durable_record(action).merge(
        "result" => "withdrawn",
        "job_id" => member.job_id,
        "job_slug" => member.job.slug
      ))
      raise StepFailed,
            "merge_train_agent withdrew #{member.job.slug}: #{action['evidence'].to_s.truncate(300)}"
    end

    def member_for_action!(train, action)
      slug = action["job_slug"].to_s
      member = train.members.includes(:job).detect { |candidate| candidate.job.slug.casecmp?(slug) }
      raise StepFailed, "merge_train_agent withdraw action named a non-member job_slug" unless member

      member
    end

    def record_no_progress!(action)
      workflow.set_artifact!(ARTIFACT_KEY, durable_record(action).merge("result" => "no_progress"))
      raise StepFailed, "merge_train_agent could not safely repair or withdraw: #{action['evidence'].to_s.truncate(300)}"
    end

    def commit_agent_changes_excluding_action_file
      chdir = workspace.path.to_s
      status = git.run("status", "--porcelain", chdir: chdir)
      return if status.strip.blank?

      git.run("add", "-A", chdir: chdir)
      git.run("reset", "--", ACTION_FILE, chdir: chdir)
      staged = git.run("diff", "--cached", "--name-only", chdir: chdir)
      return if staged.strip.blank?

      git.configure_author(BotIdentity.for(job), chdir: chdir)
      git.run("commit", "-m", "Syrus merge-train agent repair", chdir: chdir)
    end

    def durable_record(action)
      action.slice("action", "job_slug", "evidence", "changes").merge(
        "step_id" => step.id,
        "run_id" => run.id,
        "recorded_at" => Time.current.iso8601
      ).compact
    end

    def ensure_clean_worktree!
      status = git.run("status", "--porcelain", chdir: workspace.path.to_s).to_s.strip
      return if status.blank?

      raise StepFailed, "merge_train_agent left an uncommitted worktree"
    end
  end
end
