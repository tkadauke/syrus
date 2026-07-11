module Steps
  # Non-agentic incremental rebase for an Epic merge-train that failed at
  # merge_train_land because the base branch moved. Tries a mechanical
  # `git rebase FETCH_HEAD` of the integration branch onto the new base tip.
  #
  # Success path: records the new base SHA so the following
  # merge_train_land_after_rebase sees a fresh base match, and updates
  # MergeTrain#integration_sha for grader context.
  #
  # Failure path (rebase conflict): aborts and raises StepFailed with a
  # "rebuild required" message so MergeTrainFailureHandler falls back to
  # a full merge_train rebuild via LandingFailureHandler#defer_landing!.
  class MergeTrainRebase < Base
    include MergeTrainStep

    def call
      train = merge_train
      client = GithubClient.for(repository: repository, user: job.user)
      push_url = repository.authenticated_push_url(client.access_token)

      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })

      log("merge_train_rebase: fetching #{train.base_branch} to find new base tip")
      git.run("fetch", push_url, "refs/heads/#{train.base_branch}", chdir: chdir)
      new_base_sha = git.run("rev-parse", "FETCH_HEAD", chdir: chdir).strip

      old_base_sha = workflow.artifact(MergeTrainLand::BASE_SHA_ARTIFACT).to_s
      log("merge_train_rebase: rebasing integration branch #{train.integration_branch} " \
          "onto #{train.base_branch}@#{new_base_sha.first(9)} (was #{old_base_sha.first(9)})")

      begin
        git.run("rebase", "FETCH_HEAD", chdir: chdir)
      rescue GitRunner::GitError => e
        abort_rebase!(git, chdir)
        raise_rebuild_needed!(train, old_base_sha, new_base_sha,
          "incremental rebase of #{train.integration_branch} conflicted: #{e.message.truncate(200)}")
      end

      new_integration_sha = git.run("rev-parse", "HEAD", chdir: chdir).strip
      workflow.set_artifact!(MergeTrainLand::BASE_SHA_ARTIFACT, new_base_sha)
      train.update!(integration_sha: new_integration_sha)

      log("merge_train_rebase: rebased #{train.integration_branch} to " \
          "#{new_integration_sha.first(9)} (new base #{new_base_sha.first(9)})")
    end

    private

    def abort_rebase!(git, chdir)
      git.run("rebase", "--abort", chdir: chdir)
    rescue GitRunner::GitError
      nil
    end

    def raise_rebuild_needed!(train, old_base_sha, new_base_sha, detail)
      # Update the stale-base artifact so MergeTrainFailureHandler can
      # reconstruct the "base moved; rebuild required" reason string that
      # LandingFailureHandler recognises as merge_train_rebuild_required?.
      workflow.set_artifact!(
        MergeTrainLand::STALE_BASE_ARTIFACT,
        {
          "base_branch" => train.base_branch,
          "built_base_sha" => old_base_sha.presence,
          "current_base_sha" => new_base_sha,
          "reason" => "base_moved"
        }
      )
      raise StepFailed,
            "#{MergeTrainLand::STALE_BASE_FAILURE_PREFIX} from #{old_base_sha.first(12)} to " \
            "#{new_base_sha.first(12)}; rebuild required (#{detail})"
    end
  end
end
