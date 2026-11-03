module Steps
  class PublishSourceSnapshot < Base
    def call
      workspace.setup
      ref = "refs/syrus/source-snapshots/runs/#{run.id}"
      push_snapshot = lambda do
        authenticated_git("git_base_refresh_source_snapshot_push") do |url|
          GitRunner.new.run("-c", "core.hooksPath=/dev/null", "push", url, "#{head_sha}:#{ref}", chdir: workspace.path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" })
        end
      end
      begin
        push_snapshot.call
      rescue GithubPushProtection::Rejected => e
        # Repair rewrites the workspace head; the snapshot must describe the repaired commit.
        handle_push_protection_rejection!(e, &push_snapshot)
      end
      sha = head_sha
      snapshot = WorkflowSourceSnapshots.record!(workflow: workflow, creator_step: step, source_sha: sha, source_ref: ref,
        tree_sha: GitRunner.new.run("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).strip)
      workflow.set_artifact!("base_refresh_source_snapshot_id", snapshot.id)
    rescue GitRunner::GitError => e
      raise WorkflowSourceSnapshots::InfrastructureStateError, "refreshed source snapshot publication failed: #{e.message}"
    end
  end
end
