module Steps
  class BaseRefreshRebase < Base
    def call
      workspace.setup
      verify_checkpoint!
      fetch_and_verify_base!

      pre_sha = head_sha
      git.run("rebase", pinned_base_sha, chdir: workspace.path.to_s)
      post_sha = head_sha
      record_result("rebased", pre_sha: pre_sha, post_sha: post_sha)
      skip_agent_rebase!("checkpoint rebased cleanly onto the pinned base")
    rescue GitRunner::GitError => e
      if rebase_in_progress?
        record_result("conflict", pre_sha: pre_sha)
        log("[base_refresh_rebase] conflicts require agentic repair")
      else
        record_result("failed", error: e.message)
        raise StepFailed, "base refresh rebase failed safely: #{e.message}"
      end
    end

    private

    def git = @git ||= GitRunner.new

    def checkpoint_sha = workflow.artifact("checkpoint_sha").to_s
    def pinned_base_ref = workflow.artifact(RebaseTarget::BASE_BRANCH_ARTIFACT).to_s
    def pinned_base_sha = workflow.artifact(RebaseTarget::BASE_SHA_ARTIFACT).to_s

    def verify_checkpoint!
      actual = head_sha
      return if checkpoint_sha.present? && actual == checkpoint_sha

      raise StepFailed,
            "base refresh checkpoint mismatch: expected #{checkpoint_sha.presence || '(missing)'}, got #{actual}"
    end

    def fetch_and_verify_base!
      raise StepFailed, "base refresh retry has no pinned base ref or SHA" if pinned_base_ref.blank? || pinned_base_sha.blank?

      authenticated_git("git_base_refresh_fetch", repository: effective_base_repository) do |url|
        git.run("fetch", url, "refs/heads/#{pinned_base_ref}", chdir: workspace.path.to_s,
                env: { "GIT_TERMINAL_PROMPT" => "0" })
      end
      fetched_sha = git.run("rev-parse", "FETCH_HEAD", chdir: workspace.path.to_s).strip
      return if fetched_sha == pinned_base_sha

      raise StepFailed,
            "effective base moved while base refresh was starting: #{pinned_base_ref} resolved to #{fetched_sha}, expected #{pinned_base_sha}"
    end

    def effective_base_repository
      job.base_on_upstream_default? ? job.base_repository : repository
    end

    def rebase_in_progress?
      git_dir = workspace.path.join(".git")
      git_dir.join("rebase-merge").exist? || git_dir.join("rebase-apply").exist?
    end

    def record_result(status, pre_sha: nil, post_sha: nil, error: nil)
      workflow.set_artifact!("base_refresh_rebase_result", {
        "status" => status,
        "checkpoint_sha" => checkpoint_sha,
        "base_ref" => pinned_base_ref,
        "base_sha" => pinned_base_sha,
        "pre_sha" => pre_sha,
        "post_sha" => post_sha,
        "error" => error,
        "recorded_at" => Time.current.iso8601
      }.compact)
    end

    def skip_agent_rebase!(reason)
      next_step = step.next_step
      return unless next_step&.kind == "agent_rebase" && next_step.may_skip?

      next_step.skip_with_reason!(reason)
    end
  end
end
