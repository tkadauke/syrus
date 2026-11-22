module Steps
  # Agentic recovery after pr_open could not replay a stacked Job's finished
  # work onto its restacked parent (Steps::PrOpen::StackBaseRebaseConflict).
  #
  # The work has never been published, so it exists only in this workspace.
  # This step fetches the parent's current head, starts the same replay
  # (`rebase --onto <live> <prepared>`), lets the agent resolve the conflict
  # when it recurs, and verifies a completed rebase whose HEAD descends from
  # the live parent. It then records the live head as the prepared base, so the
  # pr_open after the validation loop finds the branch fresh. If the agent
  # cannot resolve the conflict, this step fails and the Workflow fails with
  # it.
  class StackBaseAgentRebase < Base
    def call
      workspace.setup
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_EDITOR" => "true" })
      conflict = workflow.artifact(PrOpen::StackBaseRebaseConflict::ARTIFACT)
      unless conflict.is_a?(Hash) && conflict["parent_ref"].present?
        fail_with!(:stack_base_rebase_conflict, "stack_base_agent_rebase: no recorded stack-base conflict to resolve")
      end

      parent_ref = conflict.fetch("parent_ref")
      abort_rebase_if_present(git)
      live = fetch_live_parent!(git, parent_ref)
      prepared = prepared_sha(conflict)
      pre_sha = head_sha

      if replay_succeeded?(git, live, prepared)
        log("stack_base_agent_rebase: replay onto #{parent_ref} (#{live.first(9)}) applied cleanly this time")
      else
        run.update!(prompt: compose_prompt(parent_ref, live, conflict)) if run.prompt.blank?
        log("invoking agent for stack_base_agent_rebase step (#{workflow.slug})")
        run_agent(prompt: run.prompt)
      end

      verify_rebase_complete!(git, parent_ref, live)
      post_sha = head_sha
      fail_with!(:stack_base_rebase_conflict, "stack_base_agent_rebase: HEAD did not move after rebasing onto #{parent_ref}") if post_sha == pre_sha

      workflow.set_artifact!(StackBaseFreshness::PREPARED_ARTIFACT, { "ref" => parent_ref, "sha" => live, "recorded_at" => Time.current.iso8601 })
      workflow.set_artifact!("stack_base_agent_rebase", { "parent_ref" => parent_ref, "live_sha" => live,
                                                           "pre_sha" => pre_sha, "post_sha" => post_sha,
                                                           "resolved_at" => Time.current.iso8601 })
      run.update!(head_sha: post_sha)
      log("stack_base_agent_rebase: rebased #{pre_sha.first(7)} -> #{post_sha.first(7)} onto #{parent_ref} (#{live.first(9)})")
    end

    private

    def live_ref(parent_ref) = "refs/remotes/origin/#{parent_ref}"

    def fetch_live_parent!(git, parent_ref)
      authenticated_git("git_stack_base_rebase_fetch", git: git) do |push_url|
        git.run("fetch", push_url, "+refs/heads/#{parent_ref}:#{live_ref(parent_ref)}", chdir: workspace.path.to_s)
      end
      git.run("rev-parse", live_ref(parent_ref), chdir: workspace.path.to_s).strip
    end

    # The parent head this work was built on: what pr_open recorded at the
    # conflict, else what the Workflow recorded when it prepared.
    def prepared_sha(conflict)
      conflict["prepared_sha"].presence ||
        workflow.artifact(StackBaseFreshness::PREPARED_ARTIFACT).then { |artifact| artifact.is_a?(Hash) ? artifact["sha"] : nil }
    end

    # Replays only this branch's own commits, as StackBaseFreshness does. A
    # rebase that stops on a conflict is left in progress for the agent.
    def replay_succeeded?(git, live, prepared)
      GitMergeDrivers.register!(git: git, path: workspace.path)
      if prepared.present? && commit_reachable_from_head?(git, prepared)
        git.run("rebase", "--onto", live, prepared, chdir: workspace.path.to_s)
      else
        git.run("rebase", live, chdir: workspace.path.to_s)
      end
      true
    rescue GitRunner::GitError
      false
    end

    def commit_reachable_from_head?(git, sha)
      git.run("merge-base", "--is-ancestor", sha, "HEAD", chdir: workspace.path.to_s)
      true
    rescue GitRunner::GitError
      false
    end

    def compose_prompt(parent_ref, live, conflict)
      Prompts::StackBaseRebase.new(
        repo_slug: repository.slug,
        branch_name: workspace.branch_name,
        parent_ref: parent_ref,
        live_ref: "#{live_ref(parent_ref)} (#{live.first(9)})",
        conflicted_files: conflict["conflicted_files"]
      ).to_s
    end

    def verify_rebase_complete!(git, parent_ref, live)
      if rebase_in_progress?(git)
        fail_with!(:stack_base_rebase_conflict,
                   "stack_base_agent_rebase: the rebase onto #{parent_ref} is still in progress; the conflict was not resolved")
      end

      status = git.run("status", "--porcelain", chdir: workspace.path.to_s).strip
      fail_with!(:stack_base_rebase_conflict, "stack_base_agent_rebase: working tree is not clean after rebase") if status.present?

      return if commit_reachable_from_head?(git, live)

      fail_with!(:stack_base_rebase_conflict,
                 "stack_base_agent_rebase: HEAD does not descend from #{parent_ref} (#{live.first(9)})",
                 evidence: { "parent_ref" => parent_ref, "live_sha" => live })
    end

    def rebase_in_progress?(git)
      %w[rebase-merge rebase-apply].any? do |name|
        path = git.run("rev-parse", "--git-path", name, chdir: workspace.path.to_s).strip
        path.present? && File.exist?(absolute_git_path(path))
      end
    rescue GitRunner::GitError
      false
    end

    def absolute_git_path(path)
      pathname = Pathname.new(path)
      pathname.absolute? ? pathname : workspace.path.join(pathname)
    end

    def abort_rebase_if_present(git)
      return unless rebase_in_progress?(git)

      log("stack_base_agent_rebase: aborting a leftover rebase before replaying")
      git.run("rebase", "--abort", chdir: workspace.path.to_s)
    rescue GitRunner::GitError
      nil
    end
  end
end
