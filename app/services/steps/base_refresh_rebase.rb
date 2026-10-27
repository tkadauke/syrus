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
      step.next_step.skip_with_reason!("checkpoint rebased cleanly onto the pinned base") if step.next_step&.may_skip?
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
      raise StepFailed, "base refresh checkpoint mismatch: expected #{checkpoint_sha.presence || '(missing)'}, got #{actual}" unless checkpoint_sha.present? && actual == checkpoint_sha
    end

    def fetch_and_verify_base!
      raise StepFailed, "base refresh retry has no pinned base ref or SHA" if pinned_base_ref.blank? || pinned_base_sha.blank?

      # The checkpoint SHA protects the unpublished work above. The base SHA is
      # only an enqueue-time observation: a refresh must be allowed to follow a
      # base that advanced while the workflow waited to run.
      current_base_sha = RepositoryContent.for(effective_base_repository, user: job.user)
        .resolve(pinned_base_ref, max_age: 0).id
      if current_base_sha != pinned_base_sha
        log("[base_refresh_rebase] stale base pin: #{pinned_base_ref} was #{pinned_base_sha} at enqueue, refreshing to #{current_base_sha}")
      end

      authenticated_git("git_base_refresh_fetch", repository: effective_base_repository) do |url|
        git.run("fetch", url, "refs/heads/#{pinned_base_ref}", chdir: workspace.path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" })
      end
      fetched = git.run("rev-parse", "FETCH_HEAD", chdir: workspace.path.to_s).strip
      unless fetched == current_base_sha
        raise StepFailed, "effective base moved during base refresh startup: #{pinned_base_ref} resolved to #{current_base_sha} immediately before fetch, but fetch returned #{fetched}; retry to resolve the latest base"
      end

      workflow.set_artifact!(RebaseTarget::BASE_SHA_ARTIFACT, fetched)
    end

    def effective_base_repository = job.base_on_upstream_default? ? job.base_repository : repository
    def rebase_in_progress? = workspace.path.join(".git/rebase-merge").exist? || workspace.path.join(".git/rebase-apply").exist?

    def record_result(status, pre_sha: nil, post_sha: nil, error: nil)
      workflow.set_artifact!("base_refresh_rebase_result", {
        "status" => status, "checkpoint_sha" => checkpoint_sha, "base_ref" => pinned_base_ref,
        "base_sha" => pinned_base_sha, "pre_sha" => pre_sha, "post_sha" => post_sha, "error" => error,
        "recorded_at" => Time.current.iso8601
      }.compact)
    end
  end
end
