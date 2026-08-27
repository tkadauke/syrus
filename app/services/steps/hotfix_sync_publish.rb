module Steps
  # Final step of HotfixSync workflow. Non-agentic. Publishes the assembled
  # (and, if needed, repaired) integration branch per
  # `DeliveryPolicy#hotfix_sync_mode`:
  #
  #   - "auto"      — push straight onto the target branch ref. No PR. The
  #     hotfix-sync equivalent of promotion's "direct" mode — named
  #     differently in `.syrus.yml` because sync-back is expected to be
  #     unattended by default (Story 5A).
  #   - "auto_pr"   — open/update a PR from the integration branch to the
  #     target branch; auto-merge immediately (hotfix sync has no
  #     maintainer-approval gate equivalent to
  #     `requires_operator_approval_for_promotion?` — the release branch
  #     already went through its own stricter landing checks).
  #   - "manual_pr" — open/update the PR but never auto-merge; a human
  #     merges it.
  #
  # Persists the resolved source/target refs as a `JobPrLink` (role:
  # "hotfix_sync") either way — `pr_number: nil`/`pr_state: "merged"` for a
  # direct push, a real PR number and "open"/"merged" for the PR-based
  # modes. Only a direct push or an immediate auto-merge closes the anchor
  # Job (closure_reason: "hotfix_sync_landed"); a PR left open for manual
  # merge leaves the Job open so the operator sees it's still awaiting
  # action.
  class HotfixSyncPublish < Base
    def call
      workspace.setup
      policy = DeliveryPolicy.for(repository: repository)
      mode = policy.hotfix_sync_mode

      if mode == "auto"
        publish_direct!
      else
        publish_via_pull_request!(mode: mode)
      end
    end

    private

    def source_branch
      workflow.artifact("hotfix_sync_source_branch")
    end

    def target_branch
      workflow.artifact("hotfix_sync_target_branch")
    end

    def publish_direct!
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_hotfix_sync_direct_push", log: method(:log)) do |push_url|
        git.run("push", push_url, "HEAD:refs/heads/#{target_branch}", chdir: workspace.path.to_s)
      end

      record_hotfix_sync_link!(pr_number: nil, pr_state: "merged")
      log("hotfix_sync_publish: pushed #{source_branch} -> #{target_branch} directly (#{workflow.slug})")
      close_job!("hotfix_sync_landed")
    rescue GitRunner::GitError => e
      raise unless push_rejected?(e)

      raise StepFailed,
            "hotfix_sync_publish: #{target_branch} moved since this hotfix sync started; refusing to overwrite newer remote work. #{e.message}"
    end

    def publish_via_pull_request!(mode:)
      push_integration_branch!
      pr_number = open_or_update_pr!
      record_hotfix_sync_link!(pr_number: pr_number, pr_state: "open")

      if mode == "auto_pr"
        merge_pull_request!(pr_number: pr_number)
      else
        log("hotfix_sync_publish: opened PR ##{pr_number} for #{source_branch} -> #{target_branch}; awaiting manual merge (mode=#{mode})")
      end
    end

    def push_integration_branch!
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_hotfix_sync_push", log: method(:log)) do |push_url|
        git.run("push", push_url, "HEAD:refs/heads/#{workspace.branch_name}", chdir: workspace.path.to_s)
      end
    end

    def open_or_update_pr!
      existing = existing_hotfix_sync_pr_number
      return existing if existing.present?

      client = GithubClient.for(repository: repository, user: job.user)
      pr_number = PullRequestOpener.new(repository, client: client).open(
        branch: workspace.branch_name,
        title: "Sync #{source_branch} into #{target_branch}",
        body: pr_body,
        base: target_branch
      )
      log("hotfix_sync_publish: opened PR ##{pr_number} (#{source_branch} -> #{target_branch})")
      pr_number
    end

    def pr_body
      "Automated hotfix sync of `#{source_branch}` into `#{target_branch}` via Syrus (#{workflow.slug}).\n\n" \
        "Review carefully — this branch was assembled and, if needed, repaired by an LLM."
    end

    def existing_hotfix_sync_pr_number
      job.pr_links.find_by(role: JobPrLink::ROLE_HOTFIX_SYNC)&.pr_number
    end

    def merge_pull_request!(pr_number:)
      client = GithubClient.for(repository: repository, user: job.user)
      merge = client.merge_pull_request(
        repository.slug,
        pr_number,
        commit_title: "Sync #{source_branch} into #{target_branch} via Syrus",
        merge_method: "merge"
      )
      merged = merge.respond_to?(:merged) ? merge.merged : merge[:merged]
      raise StepFailed, "hotfix_sync_publish: GitHub did not report PR ##{pr_number} as merged" unless merged

      record_hotfix_sync_link!(pr_number: pr_number, pr_state: "merged")
      log("hotfix_sync_publish: auto-merged PR ##{pr_number}")
      close_job!("hotfix_sync_landed")
    rescue Octokit::Error => e
      raise StepFailed, "hotfix_sync_publish: GitHub merge failed: #{e.message}"
    end

    def record_hotfix_sync_link!(pr_number:, pr_state:)
      JobPrLink.record!(
        job: job,
        role: JobPrLink::ROLE_HOTFIX_SYNC,
        source_repository_id: repository.id,
        source_ref: source_branch,
        target_repository_id: repository.id,
        target_ref: target_branch,
        pr_number: pr_number,
        metadata: { "pr_state" => pr_state }
      )
    end

    def close_job!(reason)
      job.close_with_reason!(reason) if job.open?
    end
  end
end
