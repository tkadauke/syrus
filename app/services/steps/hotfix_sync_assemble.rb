module Steps
  # First step of HotfixSync workflow. Non-agentic: deterministic
  # `git merge --no-ff origin/<source>` onto the integration branch, which
  # WorkflowWorkspace already checked out from the target branch's current
  # tip. Mirrors Steps::PromotionAssemble; the only difference is direction
  # (release branch merging into development, instead of development into
  # release).
  #
  # On a clean merge, skips the top-level hotfix_sync_repair occurrence — no
  # conflict to resolve, and prepare/grading proceed against the merged
  # tree. On conflict, aborts the merge (leaving the target's history
  # untouched) and lets the chain fall through to hotfix_sync_repair.
  class HotfixSyncAssemble < Base
    def call
      workspace.setup
      source = workflow.artifact("hotfix_sync_source_branch")
      raise StepFailed, "hotfix_sync_assemble: no source branch configured" if source.blank?

      log("hotfix_sync_assemble: merging #{source} into #{workspace.branch_name} (#{workflow.slug})")
      fetch_source!(source)

      if merge_clean?(source)
        workflow.set_artifact!("hotfix_sync_assemble_result", { "succeeded" => true })
        log("hotfix_sync_assemble: clean merge")
        skip_hotfix_sync_repair!(reason: "hotfix_sync_assemble already succeeded; no conflict to resolve")
      else
        abort_merge!
        workflow.set_artifact!("hotfix_sync_assemble_result", { "succeeded" => false, "reason" => "conflict" })
        log("hotfix_sync_assemble: conflict merging #{source} — falling through to hotfix_sync_repair")
      end
    end

    private

    def fetch_source!(source)
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_hotfix_sync_fetch_source", log: method(:log)) do |url|
        git.run("fetch", url, "+refs/heads/#{source}:refs/remotes/origin/#{source}", chdir: workspace.path.to_s)
      end
    end

    def merge_clean?(source)
      GitRunner.new.run("merge", "--no-ff", "origin/#{source}", "-m", merge_commit_message(source), chdir: workspace.path.to_s)
      true
    rescue GitRunner::GitError
      false
    end

    def merge_commit_message(source)
      "Sync #{source} into #{workflow.artifact('hotfix_sync_target_branch')}"
    end

    def abort_merge!
      GitRunner.new.run("merge", "--abort", chdir: workspace.path.to_s)
    rescue GitRunner::GitError
      nil
    end

    # Searches forward by kind rather than checking step.next_step directly:
    # prepare sits between hotfix_sync_assemble and the top-level
    # hotfix_sync_repair occurrence in the chain. loop_id: nil scopes this to
    # that top-level occurrence only — the retry_until loop's own
    # hotfix_sync_repair Step (a distinct row, non-nil loop_id) is untouched.
    def skip_hotfix_sync_repair!(reason:)
      target = workflow.steps.where(kind: "hotfix_sync_repair", loop_id: nil).order(:position).first
      return unless target&.may_skip?

      log("[#{step.kind}] skipping downstream step ##{target.id} (#{target.kind}): #{reason}")
      target.skip_with_reason!(reason)
    end
  end
end
