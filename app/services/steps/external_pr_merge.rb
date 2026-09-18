module Steps
  # Merges an approved external PR via GitHub's merge API.
  # Closes the Job on success; raises StepFailed on merge failures
  # (conflicts, failing required status checks, etc.).
  class ExternalPrMerge < Base
    include AutoMergeControl

    TRANSIENT_MERGE_ERRORS = [
      Octokit::Conflict,
      Octokit::ServiceUnavailable,
      Octokit::InternalServerError
    ].freeze

    # Mirrors Steps::Push::RemoteBranchAdvancedRebaseConflict: a rejected
    # repair-commit push onto the external PR's own branch is a real, expected
    # race (something else — the PR author, Dependabot — touched the branch
    # while landing was in flight), not a corrupt workspace or an auth/config
    # problem. Declaring `branch_diverged` here means RunFailureClassifier
    # reads it straight off the diagnostic instead of guessing from log text,
    # which is what let this exact case get misclassified as
    # provider_auth_or_config (the logged push URL embeds "x-access-token").
    class RemoteBranchAdvancedRebaseConflict < StepFailed
      # Same failure_code Steps::Push::RemoteBranchAdvancedRebaseConflict uses —
      # Problem::Kind's branch_diverged entry declares it as a known alias
      # (app/models/problem/kind.rb), so reusing the string (rather than
      # minting a new one that the registry has never heard of) is what makes
      # mark_failure_code! actually resolve a problem_code below.
      FAILURE_CODE = "remote_branch_advanced_rebase_conflict".freeze
      problem_code :branch_diverged
    end

    def call
      client = GithubClient.for(repository: repository, user: job.user)
      pr = client.pull_request(repository.slug, job.external_pr_number)

      if pr.state == "closed"
        log("external_pr_merge: PR ##{job.external_pr_number} is already closed", kind: "system")
        close_job_for_closed_pr!(pr)
        cancel_closed_workflow!
        return
      end

      return if defer_if_base_moved_since_validation!(
        client,
        pr,
        context: "external_pr_merge",
        branch_name: workflow.artifact("external_pr_head_ref").presence || pr.head&.ref
      )

      pushed_head_sha = push_same_repository_repairs!
      merge_result = merge_pull_request(client, expected_head_sha(pushed_head_sha))
      return unless merge_result

      merged = merge_result.respond_to?(:merged) ? merge_result.merged : merge_result[:merged]
      raise StepFailed, "external_pr_merge: GitHub did not report PR ##{job.external_pr_number} as merged" unless merged

      job.close_with_reason!("external_pr_merged") if job.may_close?
      log("external_pr_merge: merged external PR ##{job.external_pr_number}")
    end

    private

    def push_same_repository_repairs!
      head_repo = workflow.artifact("external_pr_head_repo")
      head_ref = workflow.artifact("external_pr_head_ref")
      original_head_sha = workflow.artifact("external_pr_head_sha")
      return unless head_repo == repository.slug && head_ref.present? && original_head_sha.present?

      workspace.setup
      local_head = GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
      return local_head if local_head == original_head_sha
      if base_move_rebase_already_published?(local_head: local_head, expected_head_sha: original_head_sha)
        log("external_pr_merge: clean base-move rebase already published #{head_ref} at #{original_head_sha}; skipping stale workspace push", kind: "system")
        return original_head_sha
      end

      log("external_pr_merge: pushing repair commit(s) to #{repository.slug}:#{head_ref}", kind: "system")
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(GithubClient.for(repository: repository, user: job.user).access_token)
      push_repair_commit!(git: git, push_url: push_url, head_ref: head_ref, local_head: local_head, expected_remote_sha: original_head_sha)
    rescue GitRunner::GitError => e
      raise StepFailed, "external_pr_merge: failed to push repair commits to #{head_ref}: #{e.message}"
    end

    # Same recovery shape as Steps::Push#push_branch: a rejected push means the
    # remote branch moved since Syrus observed it (a timing race, not a real
    # conflict), so fetch the current tip, rebase the local repair commit(s)
    # onto it, and retry once. Only a rebase conflict — or the retried push
    # itself getting rejected again — is treated as unrecoverable.
    def push_repair_commit!(git:, push_url:, head_ref:, local_head:, expected_remote_sha:)
      push_force_with_lease!(git: git, push_url: push_url, head_ref: head_ref, expected_remote_sha: expected_remote_sha)
      local_head
    rescue GitRunner::GitError => e
      raise unless push_rejected?(e)

      log("external_pr_merge: remote branch #{head_ref} advanced; rebasing repair commit(s) onto the current remote tip and retrying", kind: "system")
      retry_push_after_rebase!(git: git, push_url: push_url, head_ref: head_ref)
    end

    def retry_push_after_rebase!(git:, push_url:, head_ref:)
      remote_sha = rebase_onto_remote_branch!(git: git, push_url: push_url, head_ref: head_ref)
      rebased_head = GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
      begin
        push_force_with_lease!(git: git, push_url: push_url, head_ref: head_ref, expected_remote_sha: remote_sha)
      rescue GitRunner::GitError => e
        raise_branch_diverged!(head_ref, e)
      end
      rebased_head
    end

    def push_force_with_lease!(git:, push_url:, head_ref:, expected_remote_sha:)
      git.run(
        "push",
        "--force-with-lease=refs/heads/#{head_ref}:#{expected_remote_sha}",
        push_url,
        "HEAD:refs/heads/#{head_ref}",
        chdir: workspace.path.to_s
      )
    end

    def rebase_onto_remote_branch!(git:, push_url:, head_ref:)
      git.run("fetch", push_url, "+refs/heads/#{head_ref}:refs/remotes/origin/#{head_ref}",
              chdir: workspace.path.to_s)
      remote_sha = GitRunner.new.run("rev-parse", "refs/remotes/origin/#{head_ref}", chdir: workspace.path.to_s).strip
      run_rebase_onto_remote_branch!(git, head_ref)
      remote_sha
    end

    def run_rebase_onto_remote_branch!(git, head_ref)
      git.run("rebase", "refs/remotes/origin/#{head_ref}", chdir: workspace.path.to_s)
    rescue GitRunner::GitError => e
      abort_rebase(git)
      raise_branch_diverged!(head_ref, e)
    end

    def abort_rebase(git)
      git.run("rebase", "--abort", chdir: workspace.path.to_s)
    rescue GitRunner::GitError
      nil
    end

    def raise_branch_diverged!(head_ref, error)
      mark_failure_code!(RemoteBranchAdvancedRebaseConflict::FAILURE_CODE)
      raise RemoteBranchAdvancedRebaseConflict,
            "external_pr_merge: remote branch #{head_ref} advanced and could not be reconciled: #{error.message}"
    end

    def base_move_rebase_already_published?(local_head:, expected_head_sha:)
      rebase = workflow.artifact("landing_base_moved_rebase")
      return false unless rebase.is_a?(Hash)
      return false unless rebase["succeeded"] == true && rebase["reason"] == "rebased"

      rebase["pre_sha"].to_s == local_head && rebase["post_sha"].to_s == expected_head_sha
    end

    def expected_head_sha(pushed_head_sha)
      sha = pushed_head_sha.presence || workflow.artifact("external_pr_head_sha").to_s.presence
      return sha if sha.present?

      raise StepFailed, "external_pr_merge: missing prepared external PR head SHA"
    end

    def merge_pull_request(client, expected_sha)
      client.merge_pull_request(
        repository.slug,
        job.external_pr_number,
        commit_title: "Merge #{repository.slug}##{job.external_pr_number} via Syrus",
        merge_method: "rebase",
        sha: expected_sha
      )
    rescue Octokit::MethodNotAllowed => e
      if retryable_merge_race_error?(e)
        defer_after_transient_error!(e)
        return nil
      end

      raise StepFailed, "external_pr_merge: GitHub merge failed: #{e.message}"
    rescue Octokit::UnprocessableEntity => e
      if retryable_merge_race_error?(e)
        defer_after_transient_error!(e)
        return nil
      end

      raise StepFailed, "external_pr_merge: GitHub merge failed: #{e.message}"
    rescue *TRANSIENT_MERGE_ERRORS => e
      defer_after_transient_error!(e)
      nil
    rescue Octokit::Error => e
      raise StepFailed, "external_pr_merge: GitHub merge failed: #{e.message}"
    end

    def defer_after_transient_error!(error)
      defer_landing_for_retry!(context: "external_pr_merge", reason: error.message.to_s.first(121))
    end

    def close_job_for_closed_pr!(pr)
      return unless job.may_close?

      reason = pr.merged ? "external_pr_merged" : "external_pr_closed"
      job.close_with_reason!(reason)
    end

    def cancel_closed_workflow!
      run.cancel! if run.may_cancel?
      run.save!
      step.cancel! if step.may_cancel?
      step.save!
      WorkUnits::WorkflowCancellation.cancel!(
        workflow,
        reason: "external_pr_closed",
        artifacts: {
          "cancelled_reason" => "external_pr_closed",
          "cancelled_at" => Time.current.iso8601
        }
      )
    end
  end
end
