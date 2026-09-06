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

    # git's message when `merge-base --is-ancestor` (or any rev-walk) is
    # given a SHA that simply isn't in the local object database, as opposed
    # to a SHA that resolves fine but genuinely isn't an ancestor. The two
    # look identical as a bare GitRunner::GitError -- this distinguishes them
    # so a missing local object is never treated as proof of a failed land.
    MISSING_LOCAL_OBJECT_PATTERN = /fatal: Not a valid (?:commit|object) name/i

    # Raised when the base moved and an incremental rebase may recover without
    # a full rebuild. The Try node in Workflows::MergeTrain catches this failure
    # code and inserts merge_train_rebase → merge_train_agent_rebase → graders
    # → merge_train_land_after_rebase.
    class BaseMoved < StepFailed
      FAILURE_CODE = "merge_train_base_moved".freeze
      problem_code :merge_train_rebuild_required
    end

    def call
      train = merge_train
      client = GithubClient.for(repository: repository, user: job.user)

      pre_merge_base_sha = ensure_base_unchanged!(train, client)
      integration_sha = push_integration_branch(train, client)
      train.update!(integration_sha: integration_sha, state: "landing")

      pr = find_or_create_integration_pr(train, client)

      merge = merge_integration_pr(train, client, pr)
      merged = merge.respond_to?(:merged) ? merge.merged : merge[:merged]
      raise StepFailed, "merge_train: GitHub did not report the integration PR as merged" unless merged

      integration_sha = merge.respond_to?(:sha) ? merge.sha : merge[:sha]
      record_integration_merge_commit!(train, integration_sha)
      delete_branch_after_landing(client, train.integration_branch)
      reconcile_members!(train, client, pr, integration_sha: integration_sha)

      # "succeeded" describes the train's own atomic merge, which did
      # complete, even if reconcile_members! left an unverified member
      # behind for re-landing -- that member's own Job state (routed through
      # LandingFailureHandler) is what carries the operator-visible signal
      # from here, the same as any other individual landing failure.
      train.update!(state: "succeeded", finished_at: Time.current)
      log(
        "merge_train: landed #{train_label(train)} (#{train.members.size} PR(s)) via integration PR ##{pr.number}; " \
        "integration #{integration_sha.to_s.first(9)} merged onto #{train.base_branch}@#{pre_merge_base_sha.to_s.first(9)}"
      )
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

      return current_base_sha if current_base_sha == built_base_sha

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
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_merge_train_base_fetch", log: method(:log)) do |url|
        git.run("fetch", url, "refs/heads/#{train.base_branch}", chdir: chdir)
      end
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
      fail_with!(:merge_train_rebuild_required, "#{MISSING_BASE_FAILURE_PREFIX}; rebuild required")
    end

    def push_integration_branch(train, client)
      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_merge_train_push", log: method(:log)) do |push_url|
        git.run("push", "--force-with-lease", push_url, "HEAD:refs/heads/#{train.integration_branch}", chdir: chdir)
      end
      git.run("rev-parse", "HEAD", chdir: chdir).strip
    end

    # The integration merge commit represents the whole train landing, not
    # any single member — recorded against the Epic (Epic-backed) or the
    # MergeTrain itself (bundle-backed), never a member Job.
    # Additive bookkeeping; any failure here must not fail the landing.
    def record_integration_merge_commit!(train, integration_sha)
      return if integration_sha.blank?

      landable = landed_commit_landable(train)
      return unless landable

      LandedCommit.create!(landable: landable, sha: integration_sha, kind: "integration_merge", position: 0)
    rescue StandardError => e
      log("merge_train: could not record integration merge commit: #{e.class}: #{e.message}", kind: "system")
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
        commit_title: "Merge #{train_label(train)} via Syrus merge-train",
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
      fail_with!(:merge_train_rebase_conflict,
                 "#{INTEGRATION_CONFLICT_FAILURE_PREFIX} for PR ##{pr.number}: " \
                 "#{message.truncate(180)}; operator intervention required",
                 evidence: { pr_number: pr.number })
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
      ensure_landed_history_fetched!(train, integration_sha) if integration_sha.present?

      train.members.includes(:job).each do |member|
        member_job = member.job

        if integration_sha.present? && !member_landed?(member_job, integration_sha)
          handle_unverified_member!(member, member_job, integration_sha)
          next
        end

        reconcile_member_pull_request_after_landing(client, member_job, integration_pr)
        if member_job.may_close?
          member_job.update_column(:landed_sha, integration_sha) if integration_sha.present?
          member_job.close_with_reason!("pr_merged")
        end
        if member_job.branch_name.present?
          member_job.update_column(:branch_deleted_at, Time.current) if delete_branch_after_landing(client, member_job.branch_name)
        end
        member.update!(state: "merged")
      end
    end

    # After GitHub merges the integration PR via the API, the resulting merge
    # commit (and, for a workspace that never had them, the member commits
    # newly reachable through it) exists on GitHub but not yet in this
    # workspace's local object database -- we only fetched the base branch's
    # PRE-merge tip (ensure_base_unchanged!), and the integration branch was
    # only ever built and pushed locally, never re-fetched. Without this,
    # `git merge-base --is-ancestor` below fails with "fatal: Not a valid
    # commit name" for the merge commit itself on every landing, regardless
    # of whether any member actually landed. Additive: any failure here just
    # means the ancestry check below may come back indeterminate rather than
    # positive, which is handled without failing the step.
    def ensure_landed_history_fetched!(train, integration_sha)
      return if local_object_present?(integration_sha)

      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_merge_train_post_merge_fetch", log: method(:log)) do |url|
        git.run("fetch", url, "refs/heads/#{train.base_branch}", chdir: chdir)
      end
    rescue GitRunner::GitError => e
      log("merge_train: could not fetch #{train.base_branch} before member reconciliation: #{e.class}: #{e.message}", kind: "system")
    end

    def local_object_present?(sha)
      return false if sha.blank?

      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      git.run("cat-file", "-e", "#{sha}^{commit}", chdir: chdir)
      true
    rescue GitRunner::GitError
      false
    end

    # Guards against stamping a member as landed when its actual commits
    # (recorded by Steps::MergeTrainBuild#record_member_commits!) never made
    # it into the SHA we are about to close it against -- e.g. a stale
    # MergeTrainMember carried over from a prior failed/rebuilt train whose
    # branch was never integrated into THIS train's integration branch.
    # Verified via the last recorded LandedCommit for the member rather than
    # the member's raw (unrebased) PR branch tip, since rebasing rewrites
    # commit SHAs -- the original branch tip is never an ancestor of the
    # rebased integration history even on the happy path.
    def member_landed?(member_job, integration_sha)
      last_row = LandedCommit.where(landable: member_job, kind: "implementation").order(:position).last
      return false unless last_row

      case ancestor_of_integration(last_row.sha, integration_sha)
      when :ancestor then true
      when :not_ancestor then false
      when :indeterminate then trust_recent_build_evidence?(member_job, last_row)
      end
    end

    # `git merge-base --is-ancestor` answers through its exit status: 0 yes,
    # 1 no, anything else (128) means it could not answer at all -- a missing
    # object, a broken repository. Those are three outcomes, not two, and
    # collapsing the third into "no" is what stranded Epic 294: every member
    # of a train whose integration PR had already merged was marked failed,
    # and two further trains spent hours re-landing commits already on main.
    #
    # `workspace.setup` stays outside the rescue on purpose. A workspace that
    # will not clone is not an answer about ancestry, and classifying it as
    # one is the same mistake in a different place.
    NOT_AN_ANCESTOR_STATUS = 1

    def ancestor_of_integration(sha, integration_sha)
      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })

      begin
        git.run("merge-base", "--is-ancestor", sha, integration_sha, chdir: chdir)
        :ancestor
      rescue GitRunner::GitError => e
        # A clean exit 1 is git saying "no". Anything else -- including the
        # missing-object case, which is the common one when a Run resumes on a
        # worker whose disk never held these objects -- is git saying it
        # cannot tell, and must not be read as "did not land".
        genuine_answer?(e) ? :not_ancestor : :indeterminate
      end
    end

    def genuine_answer?(error)
      return false if missing_local_object?(error)

      error.exit_status == NOT_AN_ANCESTOR_STATUS
    end

    def missing_local_object?(error)
      error.message.to_s.match?(MISSING_LOCAL_OBJECT_PATTERN)
    end

    # Falls back to the same positive-evidence check
    # MergeTrainFailureHandler#already_landed? already relies on: the
    # member's "implementation" LandedCommit row was written by THIS
    # workflow's own merge_train_build step, moments before this land step
    # ran. That is trustworthy even when the local git object database can't
    # answer the ancestry question (e.g. this Step's Run resumed on a worker
    # whose disk doesn't hold the earlier objects this workspace once had).
    # Only a row from an older workflow attempt (a genuinely stale carryover
    # member, or nothing at all) fails through to handle_unverified_member!.
    def trust_recent_build_evidence?(member_job, last_row)
      trusted = last_row.created_at >= workflow.created_at
      if trusted
        log(
          "merge_train: could not verify #{member_job.slug}'s landed commit #{last_row.sha.to_s.first(9)} locally " \
          "(git object missing, not a reachability failure); trusting this workflow's own build-time record",
          kind: "system"
        )
      end
      trusted
    end

    # Do NOT close the PR/Job or delete the branch -- the member's work is
    # not actually reachable from what we just landed. Route it back through
    # the normal landing-failure path instead of silently treating it as
    # done (wrong) or silently dropping it (stuck in :landing forever).
    def handle_unverified_member!(member, member_job, integration_sha)
      reason = "merge_train: #{member_job.slug}'s landed commits are not reachable from " \
               "integration #{integration_sha.to_s.first(9)}; not closing as merged, needs re-landing"
      log(reason, kind: "system")
      member.update!(state: "failed", reason: reason.truncate(500))
      LandingFailureHandler.call(job: member_job, reason: reason, run: run) if member_job.landing?
    end

    def reconcile_member_pull_request_after_landing(client, member_job, integration_pr)
      return if member_job.pr_number.blank?

      cleanup_after_landing("comment on PR ##{member_job.pr_number}") do
        client.add_issue_comment(
          repository.slug,
          member_job.pr_number,
          "Landed via #{train_label(merge_train)} merge-train (integration PR ##{integration_pr.number}). #{member_job.slug}."
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
      "Land #{train_label(train)}: #{train_title(train)}".strip
    end

    def integration_pr_body(train)
      lines = [ "Atomic #{train_label(train)} landing via Syrus merge-train.", "", "Members:" ]
      train.members.includes(:job).each do |member|
        member_job = member.job
        ref = member_job.pr_number.present? ? "##{member_job.pr_number}" : member_job.slug
        lines << "- #{ref} (#{member_job.branch_name})"
      end
      lines.join("\n")
    end

    def train_label(train)
      if train.epic_backed?
        epic = train.epic
        label = epic.respond_to?(:number) && epic.number ? "Epic ##{epic.number}" : "Epic ##{epic.id}"
        return label
      end

      "job bundle ##{train.id}"
    end

    def train_title(train)
      return train.epic.title if train.epic_backed?

      "#{train.members.size} approved Jobs"
    end
  end
end
