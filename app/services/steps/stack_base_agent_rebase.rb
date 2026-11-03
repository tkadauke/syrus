module Steps
  # Agentic rung of the stacked-base finalization barrier for a rebase that
  # conflicts. pr_open already proved the completed work does not replay onto
  # the live parent; this step re-fetches the parent, recreates the rebase
  # (`--onto live prepared`), tries it deterministically once more and otherwise
  # lets the agent resolve it. It never pushes: the next pr_open re-runs the
  # required graders and repeats the live-parent check.
  class StackBaseAgentRebase < PushAgentRebase
    PROMPT_KIND = "conflict".freeze

    def call
      abort_rebase_if_present
      workspace.setup

      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      repair = workflow.artifact(StackBaseFreshness::REPAIR_ARTIFACT).to_h
      parent_ref = repair["parent_ref"].presence || RebaseTarget.branch_for(job: job, workflow: workflow)
      live_ref, live_sha = fetch_live_parent!(git, parent_ref)
      prepared = repair["prepared_sha"].presence
      pre_sha = head_sha

      workflow.set_artifact!(StackBaseFreshness::VALIDATION_PENDING_ARTIFACT, { "live_sha" => live_sha, "at" => Time.current.iso8601 })
      if rebase_clean?(git, live_sha, prepared)
        log("#{step.kind}: deterministic retry rebased cleanly onto #{live_sha[0, 8]}")
      else
        run.update!(prompt: compose_repair_prompt(repair, parent_ref, live_sha, prepared)) if run.prompt.blank?
        log("invoking agent for #{step.kind} step (#{workflow.slug})")
        run_agent(prompt: run.prompt)
      end

      verify_rebase_complete!(git, live_sha)
      post_sha = head_sha
      raise StepFailed, "#{step.kind}: HEAD did not move after rebasing onto #{live_ref}" if pre_sha == post_sha

      run.update!(head_sha: post_sha)
      log("#{step.kind}: rebased #{pre_sha[0, 7]} -> #{post_sha[0, 7]} onto #{live_sha[0, 8]}")
    end

    private

    def fetch_live_parent!(git, parent_ref)
      ref = "refs/remotes/origin/#{parent_ref}"
      authenticated_git("git_stack_base_fetch", git: git) do |url|
        git.run("fetch", url, "+refs/heads/#{parent_ref}:#{ref}", chdir: workspace.path.to_s)
      end
      [ ref, git.run("rev-parse", ref, chdir: workspace.path.to_s).strip ]
    end

    def rebase_clean?(git, live_sha, prepared)
      args = prepared.present? && commit_known?(git, prepared) ? [ "rebase", "--onto", live_sha, prepared ] : [ "rebase", live_sha ]
      git.run(*args, chdir: workspace.path.to_s)
      true
    rescue GitRunner::GitError
      false
    end

    def commit_known?(git, sha)
      git.run("cat-file", "-e", "#{sha}^{commit}", chdir: workspace.path.to_s)
      true
    rescue GitRunner::GitError
      false
    end

    def compose_repair_prompt(repair, parent_ref, live_sha, prepared)
      Prompts::StackBaseRepair.new(
        kind: self.class::PROMPT_KIND, branch_name: workspace.branch_name, parent_ref: parent_ref,
        live_sha: live_sha, prepared_sha: prepared, evidence: repair
      ).to_s
    end
  end
end
