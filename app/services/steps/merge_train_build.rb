module Steps
  # Builds the integration branch: start at the base tip, then integrate
  # each member's branch in topological order by REBASING the member's
  # commits onto the growing integration tip.
  #
  # The mechanical `git rebase` runs first — a member that only needs to
  # move forward (or whose changes don't overlap) replays cleanly with no
  # agent. On a conflict (any rebase error), Syrus leaves that rebase
  # (already targeting the integration branch) in progress and hands it to
  # the agent in a single call to resolve AND complete. Syrus then
  # verifies the outcome deterministically and fast-forwards.
  #
  # Verification is by observable end-state, NOT by rebase-internal refs:
  # `REBASE_HEAD` persists even after a rebase completes, so it can't tell
  # "still rebasing" from "done". Instead we (a) check out the scratch
  # branch — which fails if a rebase is genuinely mid-flight — then (b)
  # require a clean worktree and (c) that the integration branch is an
  # ancestor of the result (so a wrong-base rebase is caught).
  #
  # Before integrating each member Syrus checks the member's commit log for
  # placeholder commit subjects (created by the implement step before the
  # summarize step rewrites them). After all members are integrated Syrus
  # scans the integration branch for patch-id duplicates — pairs of commits
  # that apply the identical diff — and hard-fails so noisy or corrupted
  # history can't reach the base branch.
  class MergeTrainBuild < Base
    include MergeTrainStep

    AUTHENTICATED_GIT_FAILURE_PATTERN =
      /Invalid username or token|Authentication failed/i.freeze

    # Commit subjects that indicate an implement step whose summarize step
    # never completed. Any member carrying one of these must not land.
    PLACEHOLDER_COMMIT_SUBJECTS = [
      "Syrus implement step (will be rewritten by summarize)"
    ].freeze

    def call
      train = merge_train
      members = train.member_jobs
      raise StepFailed, "merge_train: no members to build" if members.empty?

      workspace.setup
      @chdir = workspace.path.to_s
      @git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_EDITOR" => "true" })
      @integration = train.integration_branch.presence || "syrus/merge-train-epic-#{train.epic_id}-#{train.id}"

      fetch_branch!(train.base_branch)
      @base_sha = @git.run("rev-parse", "FETCH_HEAD", chdir: @chdir).strip
      workflow.set_artifact!("merge_train_base_sha", @base_sha)
      @git.run("checkout", "-B", @integration, "FETCH_HEAD", chdir: @chdir)
      log("merge_train: integration branch #{@integration} started at #{train.base_branch}@#{@base_sha.first(9)}")

      members.each do |member|
        branch = member.branch_name
        raise StepFailed, "merge_train: member #{member.slug} has no branch" if branch.blank?

        fetch_branch!(branch)
        integrate!(member, branch)
      end

      check_duplicate_patch_ids!

      @git.run("checkout", @integration, chdir: @chdir)
      sha = @git.run("rev-parse", "HEAD", chdir: @chdir).strip
      train.update!(integration_branch: @integration, integration_sha: sha, state: "grading")
      log("merge_train: built #{@integration} at #{sha.first(9)} (#{members.size} member(s) integrated)")
      skip_revalidated_grade_steps!(sha) if LandingValidationCache.valid_head_for?(job: job, head_sha: sha)
    end

    private

    def fetch_branch!(branch)
      @git.run("fetch", authenticated_url, "refs/heads/#{branch}", chdir: @chdir)
    rescue GitRunner::GitError => e
      raise unless refresh_installation_token_after_auth_failure(e)

      log("merge_train: GitHub rejected the installation token while fetching #{branch}; refreshed token and retrying", kind: "system")
      @git.run("fetch", authenticated_url, "refs/heads/#{branch}", chdir: @chdir)
    end

    def authenticated_url
      token = GithubClient.for(repository: repository, user: job.user).access_token
      repository.authenticated_push_url(token)
    end

    def refresh_installation_token_after_auth_failure(error)
      return false unless git_auth_failure?(error)

      installation = GithubClient.active_installation_for(repository: repository, user: job.user)
      return false unless installation

      installation.invalidate_cached_token!
      true
    end

    def git_auth_failure?(error)
      text = "#{error.message}\n#{error.output}"
      text.match?(AUTHENTICATED_GIT_FAILURE_PATTERN)
    end

    # Replay the member's commits onto the integration tip on a scratch
    # branch, then fast-forward the integration branch to the result.
    def integrate!(member, branch)
      check_for_placeholder_commits!(member, branch)

      temp = "__mt_member_#{member.id}"
      @git.run("checkout", "-B", temp, "FETCH_HEAD", chdir: @chdir)

      begin
        @git.run("rebase", @integration, chdir: @chdir) # mechanical, clean path
      rescue GitRunner::GitError
        resolve_with_agent!(member, branch)
      end

      verify_rebased!(branch, temp)
      @git.run("checkout", @integration, chdir: @chdir)
      @git.run("merge", "--ff-only", temp, chdir: @chdir)
      @git.run("branch", "-D", temp, chdir: @chdir)
    end

    # Hand the in-progress (correctly-targeted) rebase to the agent to
    # resolve and complete. Single agent call; outcome is checked by
    # verify_rebased!.
    def resolve_with_agent!(member, branch)
      log("merge_train: conflict integrating #{branch}; agent resolving the in-progress rebase", kind: "system")
      run.update!(prompt: conflict_prompt(member, branch))
      run_agent(prompt: run.prompt)
    end

    # Deterministic verification of a correct integration:
    #   1. The scratch branch can be checked out — fails if a rebase is
    #      still mid-flight (git refuses checkout during a rebase).
    #   2. Clean worktree (no leftover conflict markers / edits).
    #   3. The integration branch is an ancestor of the result, i.e. the
    #      member was rebased onto the integration tip (not master, etc.).
    def verify_rebased!(branch, temp)
      begin
        @git.run("checkout", temp, chdir: @chdir)
      rescue GitRunner::GitError
        abort_rebase!
        raise StepFailed, "merge_train: rebase for #{branch} was not completed"
      end

      status = @git.run("status", "--porcelain", chdir: @chdir).to_s.strip
      raise StepFailed, "merge_train: integrating #{branch} left a dirty worktree" unless status.empty?

      begin
        @git.run("merge-base", "--is-ancestor", @integration, temp, chdir: @chdir)
      rescue GitRunner::GitError
        raise StepFailed, "merge_train: #{branch} was not rebased onto the integration branch"
      end
    end

    def abort_rebase!
      @git.run("rebase", "--abort", chdir: @chdir)
    rescue GitRunner::GitError
      nil
    end

    def conflict_prompt(member, branch)
      Prompts::MergeTrainConflict.new(
        repo_slug: repository.slug,
        member_branch: branch,
        integration_branch: @integration,
        pr_number: member.pr_number
      ).to_s
    end

    # Guard against placeholder commit subjects reaching the base branch.
    # Checks every commit on the member's branch above the base for a
    # known placeholder subject. A placeholder means the summarize step
    # didn't complete and the commit message was never rewritten.
    def check_for_placeholder_commits!(member, branch)
      subjects = @git.run("log", "#{@base_sha}..FETCH_HEAD", "--format=%s", chdir: @chdir)
                     .to_s.lines.map(&:strip).reject(&:empty?)
      found = subjects.find { |s| PLACEHOLDER_COMMIT_SUBJECTS.include?(s) }
      return unless found

      raise StepFailed,
        "merge_train: member #{member.slug} (#{branch}) contains a placeholder commit " \
        "(\"#{found}\") — the summarize step may not have completed. " \
        "Re-approve the Epic after the member branch is updated with a proper commit message."
    end

    # Guard against duplicate patches reaching the base branch. After all
    # members are integrated we scan every commit above the base; two commits
    # with the identical diff (same fingerprint) indicate that the same
    # change landed twice — typically from overlapping or redundant member
    # branches. Hard-fail so the operator can deduplicate before re-approving.
    def check_duplicate_patch_ids!
      shas = @git.run("log", "--format=%H", "#{@base_sha}..HEAD", chdir: @chdir)
                 .to_s.lines.map(&:strip).reject(&:empty?)
      return if shas.size < 2

      seen = {}
      shas.each do |sha|
        diff = @git.run("diff-tree", "-p", "--no-commit-id", sha, chdir: @chdir).to_s
        next if diff.empty?

        fingerprint = Digest::SHA256.hexdigest(diff)

        if (dupe_sha = seen[fingerprint])
          subj = @git.run("log", "-1", "--format=%s", sha, chdir: @chdir).to_s.strip
          raise StepFailed,
            "merge_train: duplicate commits #{sha.first(9)} and #{dupe_sha.first(9)} apply the same patch " \
            "(\"#{subj.truncate(80)}\") — re-approve the Epic after deduplicating the member branches"
        end

        seen[fingerprint] = sha
      end
    end

    def skip_revalidated_grade_steps!(sha)
      log("merge_train: reusing cached grading validation for #{sha.first(7)}", kind: "system")
      Step.suppress_cancel_cascade do
        cursor = step.next_step
        while cursor && cursor.kind != "merge_train_land"
          if cursor.may_cancel?
            cursor.cancellation_reason = "landing_validation_cached"
            cursor.cancel!
            cursor.save!
          end
          cursor = cursor.next_step
        end
      end
    end
  end
end
