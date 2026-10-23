module Steps
  class PublishSourceSnapshot < Base
    def call
      workspace.setup
      sha = head_sha
      ref = "refs/syrus/source-snapshots/runs/#{run.id}"
      authenticated_git("git_base_refresh_source_snapshot_push") do |url|
        GitRunner.new.run("push", url, "#{sha}:#{ref}", chdir: workspace.path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" })
      end
      snapshot = WorkflowSourceSnapshots.record!(workflow: workflow, creator_step: step, source_sha: sha, source_ref: ref,
        tree_sha: GitRunner.new.run("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).strip)
      workflow.set_artifact!("base_refresh_source_snapshot_id", snapshot.id)
    rescue GitRunner::GitError => e
      raise WorkflowSourceSnapshots::InfrastructureStateError, "refreshed source snapshot publication failed: #{e.message}"
    end
  end
end
