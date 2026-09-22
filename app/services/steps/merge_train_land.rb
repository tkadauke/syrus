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
    MEMBER_RECONCILIATION_ARTIFACT = "merge_train_member_reconciliation"
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

      if (already_on_base = integration_branch_already_on_base?(train, pre_merge_base_sha))
        settle_train_already_on_base!(train, client, already_on_base)
        return
      end

      integration_sha = push_integration_branch(train, client)
      train.update!(integration_sha: integration_sha, state: "landing")

      pr = find_or_create_integration_pr(train, client)

      merge = merge_integration_pr(train, client, pr)
      merged = merge.respond_to?(:merged) ? merge.merged : merge[:merged]
      raise StepFailed, "merge_train: GitHub did not report the integration PR as merged" unless merged

      integration_sha = merge.respond_to?(:sha) ? merge.sha : merge[:sha]
      record_integration_merge_commit!(train, integration_sha)
      delete_branch_after_landing(client, train.integration_branch)
      unverified_members = reconcile_members_after_landing!(train, client, pr, integration_sha: integration_sha)
      finish_landed_train!(train, integration_sha, unverified_members)
      log(
        "merge_train: landed #{train.label} (#{train.members.size} PR(s)) via integration PR ##{pr.number}; " \
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

    # An integration branch with nothing ahead of base means every commit the
    # build put on it is already on base -- the members landed, typically
    # through an earlier train whose member reconciliation could not verify
    # them and so never closed their Jobs.
    #
    # Pushing that branch and asking GitHub to open a PR for it earns a 422
    # "No commits between", which failed the train, reverted the members, and
    # left them to be re-landed by another train that would be just as empty.
    # Epic #296 spent from 01:59 to 03:38 Eastern in that loop across 26
    # consecutive single-member trains before it escaped by accident. It is
    # the single largest cause of merge-train failure on this instance.
    #
    # Returns the base SHA the members are already on, or nil.
    def integration_branch_already_on_base?(train, base_sha)
      return nil if base_sha.blank?

      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      ahead = git.run("rev-list", "--count", "#{base_sha}..HEAD", chdir: chdir).to_s.strip
      return nil unless ahead == "0"

      base_sha
    rescue StandardError => e
      # Unknowable reads as "not empty", and every failure mode is caught, not
      # just git's: this is a measurement taken to avoid a bad outcome, so it
      # must never itself become one. The normal path still verifies every
      # member before closing it, so guessing wrong here costs an attempt
      # rather than closing work that did not land.
      log("merge_train: could not measure #{train.integration_branch} against base (#{e.class}: #{e.message.to_s.lines.first.to_s.strip})")
      nil
    end

    # Same verification the normal landing path uses -- reconcile_members!
    # checks each member's recorded commits against the SHA we claim it landed
    # in, and routes anything it cannot verify through handle_unverified_member!
    # exactly as before. The only difference is that the SHA is the existing
    # base tip rather than a merge commit we just created.
    def settle_train_already_on_base!(train, client, base_sha)
      log(
        "merge_train: #{train.integration_branch} has no commits ahead of #{train.base_branch}@#{base_sha.to_s.first(9)}; " \
        "its members are already on base, so there is nothing to merge",
        kind: "system"
      )
      train.update!(integration_sha: base_sha, state: "landing")
      delete_branch_after_landing(client, train.integration_branch)
      unverified_members = reconcile_members_after_landing!(train, client, nil, integration_sha: base_sha)
      finish_landed_train!(train, base_sha, unverified_members)
    end

    def push_integration_branch(train, client)
      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      branch = train.integration_branch
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_merge_train_push", log: method(:log)) do |push_url|
        git.run("push", *push_lease_args(git, chdir, branch, push_url), push_url, "HEAD:refs/heads/#{branch}", chdir: chdir)
      end
      git.run("rev-parse", "HEAD", chdir: chdir).strip
    end

    # A bare `--force-with-lease` leases against the remote-tracking ref -- and
    # we push to a URL, not a named remote, so git has no tracking namespace to
    # read and refuses the push outright with "stale info".
    #
    # That went unnoticed for as long as the integration branch did not exist
    # on the remote until this very push: with no ref to protect, git allowed
    # it. Once `merge_train_build` started publishing the branch at build time,
    # every land had something to lease against and every land failed. Four
    # trains died that way (5115, 5117, 5238, 5239), each one clearing its
    # members' approvals on the way out.
    #
    # So state the lease explicitly, the way Steps::ForcePush already does.
    # `ls-remote` is the source of truth for what we are overwriting; no remote
    # branch means there is nothing to protect and a plain push creates it.
    def push_lease_args(git, chdir, branch, push_url)
      expected = remote_branch_sha(git, chdir, branch, push_url)
      return [] if expected.blank?

      [ "--force-with-lease=refs/heads/#{branch}:#{expected}" ]
    end

    def remote_branch_sha(git, chdir, branch, push_url)
      output = git.run("ls-remote", "--heads", push_url, "refs/heads/#{branch}", chdir: chdir)
      output.to_s.split(/\s+/).first.presence
    rescue GitRunner::GitError => e
      log("merge_train: could not read the remote tip of #{branch} (#{e.message.to_s.lines.first.to_s.strip}); pushing without a lease")
      nil
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
        commit_title: "Merge #{train.label} via Syrus merge-train",
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
      unverified_members = []

      train.members.includes(:job).each do |member|
        member_job = member.job

        if integration_sha.present? && !member_landed?(member_job, integration_sha, train: train, client: client)
          handle_unverified_member!(member, member_job, integration_sha)
          unverified_members << member
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

      unverified_members
    end

    # GitHub merging the integration PR is the publication commit point. A
    # later API, git, or bookkeeping error cannot undo it, so it must not turn
    # this workflow into a failed landing that republishes the same train.
    # Preserve every member not already reconciled as unresolved and let the
    # normal post-land reconciler finish the bookkeeping from recorded commit
    # evidence.
    def reconcile_members_after_landing!(train, client, integration_pr, integration_sha:)
      reconcile_members!(train, client, integration_pr, integration_sha: integration_sha)
    rescue StandardError => e
      reason = "merge_train: integration #{integration_sha.to_s.first(9)} merged, but member reconciliation " \
               "stopped after #{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
      log(reason, kind: "system")
      train.members.includes(:job).reject { |member| member.state == "merged" }.each do |member|
        member.update_columns(state: "failed", reason: reason.truncate(500), updated_at: Time.current)
        LandingFailureHandler.call(job: member.job, reason: reason, run: run) if member.job&.landing?
      rescue StandardError => member_error
        log(
          "merge_train: could not record unresolved member #{member.job_id}: " \
          "#{member_error.class}: #{member_error.message}",
          kind: "system"
        )
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
    def member_landed?(member_job, integration_sha, train:, client:)
      last_row = LandedCommit.where(landable: member_job, kind: "implementation").order(:position).last
      return false unless last_row

      case ancestor_of_integration(last_row.sha, integration_sha)
      when :ancestor then true
      when :not_ancestor then patch_equivalent_on_landed_base?(member_job, train, client)
      when :indeterminate then trust_recent_build_evidence?(member_job, last_row) || patch_equivalent_on_landed_base?(member_job, train, client)
      end
    end

    # The ancestry check above answers "is the commit we rebased THIS build
    # a literal ancestor of what we just landed" -- but a member's most
    # recently recorded LandedCommit can point at a rebase from a build whose
    # integration branch was later discarded, even though that member's actual
    # diff already reached the base branch through an earlier, different
    # build that landed successfully. Ancestry can never see that: the two
    # commits share content, not lineage. `git cherry`-based patch equivalence
    # (BranchPatchPresence, already trusted for this exact "landed some other
    # way" question when closing a Job whose PR was closed unmerged) can. Only
    # reached once ancestry has already said no or could not say -- this is a
    # fallback, not a replacement, because it costs a full clone of the base
    # branch.
    def patch_equivalent_on_landed_base?(member_job, train, client)
      return false if member_job.branch_name.blank?

      classification = BranchPatchPresence.classify(
        job: member_job, pr: nil, client: client, base_ref: train.base_branch,
        git: streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      )
      landed = classification == BranchPatchPresence::ALL_LANDED
      log(
        "merge_train: #{member_job.slug}'s recorded landed commit is not an ancestor of the integration, but its " \
        "branch is patch-equivalent to what's already on #{train.base_branch} (classification=#{classification}); " \
        "#{landed ? "treating it as landed" : "still needs re-landing"}",
        kind: "system"
      )
      landed
    rescue StandardError => e
      log("merge_train: patch-equivalence fallback for #{member_job.slug} failed: #{e.class}: #{e.message}", kind: "system")
      false
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

    # Once the integration commit is on the base branch, landing is complete
    # and must never be retried as though publication failed. Member
    # reconciliation is conservative bookkeeping after that irreversible
    # boundary: verified members close normally, while unresolved members
    # remain open and failed on this train so the reconciler can inspect and
    # repair them independently.
    def finish_landed_train!(train, integration_sha, unverified_members)
      slugs = unverified_members.map { |member| member.job&.slug }.compact
      train.update!(state: "succeeded", failure_reason: nil, finished_at: Time.current)
      return if unverified_members.empty?

      reason = "merge_train: landed integration #{integration_sha.to_s.first(9)} but could not verify " \
               "#{slugs.size}/#{train.members.size} member(s): #{slugs.join(', ')}; " \
               "landing succeeded and unresolved members remain open for reconciliation"
      workflow.set_artifact!(
        MEMBER_RECONCILIATION_ARTIFACT,
        {
          "status" => "partial",
          "integration_sha" => integration_sha,
          "member_count" => train.members.size,
          "unresolved_job_ids" => unverified_members.map(&:job_id)
        }
      )
      log(reason, kind: "system")
    end

    def reconcile_member_pull_request_after_landing(client, member_job, integration_pr)
      MergeTrainMemberPrReconciler.call(
        client: client,
        repository: repository,
        train: merge_train,
        member_job: member_job,
        integration_pr: integration_pr,
        log: method(:log)
      )
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
      "Land #{train.label}: #{train_title(train)}".strip
    end

    def integration_pr_body(train)
      lines = [ "Atomic #{train.label} landing via Syrus merge-train.", "", "Members:" ]
      train.members.includes(:job).each do |member|
        member_job = member.job
        ref = member_job.pr_number.present? ? "##{member_job.pr_number}" : member_job.slug
        lines << "- #{ref} (#{member_job.branch_name})"
      end
      lines.join("\n")
    end

    def train_title(train)
      return train.epic.title if train.epic_backed?

      "#{train.members.size} approved Jobs"
    end
  end
end
