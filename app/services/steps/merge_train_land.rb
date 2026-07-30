module Steps
  # Final step: land the graded integration branch into the base in a
  # SINGLE atomic merge, then reconcile the child PRs. Because the merge
  # is atomic, child PR head SHAs are not ancestors of base — the child
  # PRs are closed (not "merged" on GitHub) with a back-link, and their
  # Jobs are marked closed/pr_merged. See docs/plans/landing-merge-train.md.
  class MergeTrainLand < Base
    include MergeTrainStep

    BASE_SHA_ARTIFACT = "merge_train_base_sha"
    STALE_BASE_ARTIFACT = "merge_train_stale_base"
    INTEGRATION_PR_ARTIFACT = "merge_train_pr_number"
    STALE_BASE_FAILURE_PREFIX = "merge_train: base moved"
    MISSING_BASE_FAILURE_PREFIX = "merge_train: missing built base SHA"
    INTEGRATION_CONFLICT_FAILURE_PREFIX = "merge_train: integration PR has merge conflicts"

    # Raised when the base moved and an incremental rebase may recover without
    # a full rebuild. The Try node in Workflows::MergeTrain catches this failure
    # code and inserts merge_train_rebase → graders → merge_train_land_after_rebase.
    class BaseMoved < StepFailed
      FAILURE_CODE = "merge_train_base_moved".freeze
    end

    def call
      train = merge_train
      client = GithubClient.for(repository: repository, user: job.user)

      ensure_base_unchanged!(train, client)
      integration_sha = push_integration_branch(train, client)
      train.update!(integration_sha: integration_sha, state: "landing")

      pr = find_or_create_integration_pr(train, client)

      merge = merge_integration_pr(train, client, pr)
      merged = merge.respond_to?(:merged) ? merge.merged : merge[:merged]
      raise StepFailed, "merge_train: GitHub did not report the integration PR as merged" unless merged

      integration_sha = merge.respond_to?(:sha) ? merge.sha : merge[:sha]
      delete_branch_after_landing(client, train.integration_branch)
      reconcile_members!(train, client, pr, integration_sha: integration_sha)

      train.update!(state: "succeeded", finished_at: Time.current)
      log("merge_train: landed Epic ##{epic.id} (#{train.members.size} PR(s)) via integration PR ##{pr.number}")
    end

    private

    def ensure_base_unchanged!(train, client)
      built_base_sha = workflow.artifact(BASE_SHA_ARTIFACT).to_s.presence
      current_base_sha = fetch_current_base_sha(train, client)

      if built_base_sha.blank?
        close_open_integration_pr!(
          train,
          client,
          "Superseded by a rebuilt Syrus merge-train because this workflow predates base tracking."
        )
        raise_missing_base!(train, current_base_sha)
      end

      return if current_base_sha == built_base_sha

      # Base moved — record stale-base info and raise a typed failure so the
      # Try node in Workflows::MergeTrain can insert an incremental rebase
      # instead of triggering a full rebuild. We do NOT close the integration
      # PR here: it doesn't exist yet (push hasn't happened), and even if it
      # did, force-pushing the rebased branch would update it automatically.
      record_stale_base!(train, built_base_sha, current_base_sha)
      mark_failure_code!(BaseMoved::FAILURE_CODE)
      raise BaseMoved,
            "#{STALE_BASE_FAILURE_PREFIX} from #{built_base_sha.first(12)} to #{current_base_sha.first(12)}; attempting incremental rebase"
    end

    def fetch_current_base_sha(train, client)
      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(client.access_token)
      git.run("fetch", push_url, "refs/heads/#{train.base_branch}", chdir: chdir)
      git.run("rev-parse", "FETCH_HEAD", chdir: chdir).strip
    end

    def record_stale_base!(train, built_base_sha, current_base_sha)
      workflow.set_artifact!(
        STALE_BASE_ARTIFACT,
        {
          "base_branch" => train.base_branch,
          "built_base_sha" => built_base_sha,
          "current_base_sha" => current_base_sha,
          "reason" => "base_moved"
        }
      )
    end

    def raise_missing_base!(train, current_base_sha)
      workflow.set_artifact!(
        STALE_BASE_ARTIFACT,
        {
          "base_branch" => train.base_branch,
          "built_base_sha" => nil,
          "current_base_sha" => current_base_sha,
          "reason" => "missing_built_base_sha"
        }
      )
      raise StepFailed, "#{MISSING_BASE_FAILURE_PREFIX}; rebuild required"
    end

    def push_integration_branch(train, client)
      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(client.access_token)
      git.run("push", "--force-with-lease", push_url, "HEAD:refs/heads/#{train.integration_branch}", chdir: chdir)
      git.run("rev-parse", "HEAD", chdir: chdir).strip
    end

    def find_or_create_integration_pr(train, client)
      existing = stored_integration_pr(client) || open_integration_pr(train, client)
      return existing if existing

      pr = client.create_pull_request(
        repository.slug,
        base: train.base_branch,
        head: train.integration_branch,
        title: integration_pr_title(train),
        body: integration_pr_body(train)
      )
      workflow.set_artifact!(INTEGRATION_PR_ARTIFACT, pr.number)
      pr
    rescue Octokit::UnprocessableEntity
      existing = open_integration_pr(train, client)
      return existing if existing

      raise
    end

    def stored_integration_pr(client)
      pr_number = workflow.artifact(INTEGRATION_PR_ARTIFACT).to_s.presence
      return if pr_number.blank?

      pr = client.pull_request(repository.slug, pr_number, bypass_cache: true)
      open_pull_request?(pr) ? pr : nil
    rescue Octokit::NotFound
      nil
    end

    def open_integration_pr(train, client)
      pr = client.open_pull_request_for_head(
        repository.slug,
        base: train.base_branch,
        head: "#{repository.owner}:#{train.integration_branch}"
      )
      workflow.set_artifact!(INTEGRATION_PR_ARTIFACT, pr.number) if pr
      pr
    end

    def open_pull_request?(pr)
      state = pr.respond_to?(:state) ? pr.state : pr[:state]
      state.to_s == "open"
    end

    def merge_integration_pr(train, client, pr)
      client.merge_pull_request(
        repository.slug,
        pr.number,
        commit_title: "Merge Epic ##{epic.id} via Syrus merge-train",
        merge_method: "merge"
      )
    rescue Octokit::MethodNotAllowed => e
      built_base_sha = workflow.artifact(BASE_SHA_ARTIFACT).to_s.presence
      current_base_sha = fetch_current_base_sha(train, client)

      if built_base_sha.blank?
        close_integration_pr!(
          client,
          pr,
          "Superseded by a rebuilt Syrus merge-train because this workflow predates base tracking."
        )
        raise_missing_base!(train, current_base_sha)
      end

      if current_base_sha != built_base_sha
        # Base moved while the train was landing. Close this integration PR
        # (the rebased branch will need a fresh one with the updated tip) and
        # raise BaseMoved so the Try node can insert an incremental rebase.
        close_integration_pr!(
          client,
          pr,
          "Closed by Syrus because #{train.base_branch} moved while this train was landing; will attempt incremental rebase."
        )
        record_stale_base!(train, built_base_sha, current_base_sha)
        mark_failure_code!(BaseMoved::FAILURE_CODE)
        raise BaseMoved,
              "#{STALE_BASE_FAILURE_PREFIX} from #{built_base_sha.first(12)} to #{current_base_sha.first(12)}; attempting incremental rebase"
      end

      close_integration_pr!(
        client,
        pr,
        "Closed by Syrus because the merge-train integration PR could not be merged cleanly. Re-approve the Epic jobs after resolving the conflict."
      )
      message = e.message.to_s.presence || "GitHub refused the integration merge"
      raise StepFailed, "#{INTEGRATION_CONFLICT_FAILURE_PREFIX} for PR ##{pr.number}: #{message.truncate(180)}; operator intervention required"
    end

    def close_open_integration_pr!(train, client, reason)
      pr = stored_integration_pr(client) || open_integration_pr(train, client)
      close_integration_pr!(client, pr, reason) if pr
    end

    def close_integration_pr!(client, pr, reason)
      return unless pr

      pr_number = pr.respond_to?(:number) ? pr.number : pr[:number]
      client.add_issue_comment(repository.slug, pr_number, reason)
      client.close_pull_request(repository.slug, pr_number)
      log("merge_train: closed superseded integration PR ##{pr_number}")
    rescue Octokit::NotFound
      nil
    end

    def reconcile_members!(train, client, integration_pr, integration_sha: nil)
      train.members.includes(:job).each do |member|
        member_job = member.job
        reconcile_member_pull_request_after_landing(client, member_job, integration_pr)
        if member_job.open?
          member_job.update_column(:landed_sha, integration_sha) if integration_sha.present?
          member_job.close_with_reason!("pr_merged")
        end
        if member_job.branch_name.present?
          member_job.update_column(:branch_deleted_at, Time.current) if delete_branch_after_landing(client, member_job.branch_name)
        end
        member.update!(state: "merged")
      end
    end

    def reconcile_member_pull_request_after_landing(client, member_job, integration_pr)
      return if member_job.pr_number.blank?

      cleanup_after_landing("comment on PR ##{member_job.pr_number}") do
        client.add_issue_comment(
          repository.slug,
          member_job.pr_number,
          "Landed via Epic merge-train (integration PR ##{integration_pr.number}). #{member_job.slug}."
        )
      end
      cleanup_after_landing("close PR ##{member_job.pr_number}") do
        client.close_pull_request(repository.slug, member_job.pr_number)
      end
    end

    def delete_branch_after_landing(client, branch_name)
      deleted = cleanup_after_landing("delete branch #{branch_name}") do
        client.delete_branch(repository.slug, branch_name)
      end
      log("merge_train: cleanup left #{branch_name} for a later retry", kind: "system") unless deleted
      deleted
    end

    def cleanup_after_landing(description)
      yield
    rescue Octokit::TooManyRequests, Octokit::Error => e
      log("merge_train: cleanup could not #{description}: #{e.class}: #{e.message}", kind: "system")
      false
    end

    def integration_pr_title(train)
      label = epic.respond_to?(:number) && epic.number ? "Epic ##{epic.number}" : "Epic ##{epic.id}"
      "Land #{label}: #{epic.title}".strip
    end

    def integration_pr_body(train)
      lines = [ "Atomic Epic landing via Syrus merge-train.", "", "Members:" ]
      train.members.includes(:job).each do |member|
        member_job = member.job
        ref = member_job.pr_number.present? ? "##{member_job.pr_number}" : member_job.slug
        lines << "- #{ref} (#{member_job.branch_name})"
      end
      lines.join("\n")
    end
  end
end
