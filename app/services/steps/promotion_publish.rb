module Steps
  # Final step of Promotion workflow. Non-agentic. Publishes the assembled
  # (and, if needed, repaired) integration branch per
  # `DeliveryPolicy#promotion_mode`:
  #
  #   - "direct"   — push straight onto the target branch ref. No PR.
  #   - "auto_pr"  — open/update a PR from the integration branch to the
  #     target branch; auto-merge immediately unless
  #     `DeliveryPolicy#requires_operator_approval_for_promotion?`.
  #   - "manual_pr" — open/update the PR but never auto-merge; a human
  #     merges it.
  #
  # Persists the resolved source/target refs as a `JobPrLink` (role:
  # "promotion") either way — `pr_number: nil`/`pr_state: "merged"` for a
  # direct push (there's no PR, but the ref movement is complete), a real
  # PR number and "open"/"merged" for the PR-based modes. Only a direct push
  # or an immediate auto-merge closes the anchor Job (closure_reason:
  # "promotion_landed"); a PR left open for manual/gated merge leaves the
  # Job open so the operator sees it's still awaiting action.
  class PromotionPublish < Base
    def call
      workspace.setup
      policy = DeliveryPolicy.for(repository: repository)
      PublishMode.for(policy.promotion_mode).new(self, policy: policy).publish
    end

    private

    class PublishMode
      MODES = {
        "direct" => "Steps::PromotionPublish::PublishMode::Direct",
        "auto_pr" => "Steps::PromotionPublish::PublishMode::AutoPr",
        "manual_pr" => "Steps::PromotionPublish::PublishMode::ManualPr"
      }.freeze

      def self.for(mode)
        MODES.fetch(mode.to_s).constantize
      end

      def initialize(publisher, policy:)
        @publisher = publisher
        @policy = policy
      end

      private

      attr_reader :publisher, :policy

      def mode
        policy.promotion_mode
      end
    end

    class PublishMode::Direct < PublishMode
      def publish
        publisher.send(:publish_direct!)
      end
    end

    class PublishMode::AutoPr < PublishMode
      def publish
        publisher.send(
          :publish_via_pull_request!,
          mode: mode,
          auto_merge: !policy.requires_operator_approval_for_promotion?
        )
      end
    end

    class PublishMode::ManualPr < PublishMode
      def publish
        publisher.send(:publish_via_pull_request!, mode: mode, auto_merge: false)
      end
    end

    def source_branch
      workflow.artifact("promotion_source_branch")
    end

    def target_branch
      workflow.artifact("promotion_target_branch")
    end

    def publish_direct!
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_promotion_direct_push", log: method(:log)) do |push_url|
        git.run("push", push_url, "HEAD:refs/heads/#{target_branch}", chdir: workspace.path.to_s)
      end

      record_promotion_link!(pr_number: nil, pr_state: "merged")
      log("promotion_publish: pushed #{source_branch} -> #{target_branch} directly (#{workflow.slug})")
      close_job!("promotion_landed")
    rescue GitRunner::GitError => e
      raise unless push_rejected?(e)

      raise StepFailed,
            "promotion_publish: #{target_branch} moved since this promotion started; refusing to overwrite newer remote work. #{e.message}"
    end

    def publish_via_pull_request!(mode:, auto_merge:)
      push_integration_branch!
      pr_number = open_or_update_pr!
      record_promotion_link!(pr_number: pr_number, pr_state: "open")

      if auto_merge
        merge_pull_request!(pr_number: pr_number)
      else
        log("promotion_publish: opened PR ##{pr_number} for #{source_branch} -> #{target_branch}; awaiting manual merge (mode=#{mode})")
      end
    end

    def push_integration_branch!
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_promotion_push", log: method(:log)) do |push_url|
        git.run("push", push_url, "HEAD:refs/heads/#{workspace.branch_name}", chdir: workspace.path.to_s)
      end
    end

    def open_or_update_pr!
      existing = existing_promotion_pr_number
      return existing if existing.present?

      client = GithubClient.for(repository: repository, user: job.user)
      pr_number = PullRequestOpener.new(repository, client: client).open(
        branch: workspace.branch_name,
        title: "Promote #{source_branch} into #{target_branch}",
        body: pr_body,
        base: target_branch
      )
      log("promotion_publish: opened PR ##{pr_number} (#{source_branch} -> #{target_branch})")
      pr_number
    end

    def pr_body
      "Automated promotion of `#{source_branch}` into `#{target_branch}` via Syrus (#{workflow.slug}).\n\n" \
        "Review carefully — this branch was assembled and, if needed, repaired by an LLM.\n\n" \
        "#{PrProvenanceMarker.stamp(kind: 'syrus_promotion', job: job)}"
    end

    def existing_promotion_pr_number
      job.pr_links.find_by(role: JobPrLink::ROLE_PROMOTION)&.pr_number
    end

    def merge_pull_request!(pr_number:)
      client = GithubClient.for(repository: repository, user: job.user)
      merge = client.merge_pull_request(
        repository.slug,
        pr_number,
        commit_title: "Promote #{source_branch} into #{target_branch} via Syrus",
        merge_method: "merge"
      )
      merged = merge.respond_to?(:merged) ? merge.merged : merge[:merged]
      raise StepFailed, "promotion_publish: GitHub did not report PR ##{pr_number} as merged" unless merged

      record_promotion_link!(pr_number: pr_number, pr_state: "merged")
      log("promotion_publish: auto-merged PR ##{pr_number}")
      close_job!("promotion_landed")
    rescue Octokit::Error => e
      raise StepFailed, "promotion_publish: GitHub merge failed: #{e.message}"
    end

    def record_promotion_link!(pr_number:, pr_state:)
      JobPrLink.record!(
        job: job,
        role: JobPrLink::ROLE_PROMOTION,
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
