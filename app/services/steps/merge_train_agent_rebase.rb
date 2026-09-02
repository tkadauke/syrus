module Steps
  # Agentic fallback for merge_train_rebase. The previous step attempted to
  # rebase the integration branch onto the moved base and left the conflicted
  # rebase in progress for this step to resolve.
  class MergeTrainAgentRebase < Base
    include MergeTrainStep

    def call
      train = merge_train
      workspace.setup
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_EDITOR" => "true" })
      chdir = workspace.path.to_s

      new_base_sha = workflow.artifact("merge_train_rebase_new_base_sha").to_s
      raise StepFailed, "merge_train_agent_rebase: missing moved base SHA; rebuild required" if new_base_sha.blank?
      run.update!(prompt: compose_prompt(train, new_base_sha)) if run.prompt.blank?

      log("invoking agent for merge_train_agent_rebase step (#{workflow.slug})")
      run_agent(prompt: run.prompt)

      verify_rebase_complete!(git, train, new_base_sha, chdir)
      new_integration_sha = git.run("rev-parse", "HEAD", chdir: chdir).strip
      workflow.set_artifact!(MergeTrainLand::BASE_SHA_ARTIFACT, new_base_sha)
      train.update!(integration_sha: new_integration_sha)
      run.update!(head_sha: new_integration_sha)

      log("merge_train_agent_rebase: rebased #{train.integration_branch} to " \
          "#{new_integration_sha.first(9)} (new base #{new_base_sha.first(9)})")
    end

    private

    def compose_prompt(train, new_base_sha)
      Prompts::MergeTrainRebaseConflict.new(
        repo_slug: repository.slug,
        integration_branch: train.integration_branch,
        base_branch: train.base_branch,
        new_base_sha: new_base_sha
      ).to_s
    end

    def verify_rebase_complete!(git, train, new_base_sha, chdir)
      if rebase_in_progress?(git, chdir)
        raise StepFailed, "merge_train_agent_rebase: rebase is still in progress; run git rebase --continue until it completes"
      end

      status = git.run("status", "--porcelain", chdir: chdir).strip
      raise StepFailed, "merge_train_agent_rebase: working tree is not clean after rebase" if status.present?

      git.run("merge-base", "--is-ancestor", new_base_sha, "HEAD", chdir: chdir)
      git.run("merge-base", "--is-ancestor", new_base_sha, train.integration_branch, chdir: chdir)
    rescue GitRunner::GitError => e
      raise StepFailed, "merge_train_agent_rebase: #{train.integration_branch} was not rebased onto the moved base: #{e.message}"
    end

    def rebase_in_progress?(git, chdir)
      %w[rebase-merge rebase-apply].any? do |name|
        path = git.run("rev-parse", "--git-path", name, chdir: chdir).strip
        path.present? && File.exist?(absolute_git_path(path))
      end
    rescue GitRunner::GitError
      false
    end

    def absolute_git_path(path)
      pathname = Pathname.new(path)
      pathname.absolute? ? pathname : workspace.path.join(pathname)
    end
  end
end
