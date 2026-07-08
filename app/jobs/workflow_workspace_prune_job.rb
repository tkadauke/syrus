class WorkflowWorkspacePruneJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  # Succeeded/cancelled workflows: their AASM callbacks should have
  # already cleaned the workspace. This backstop catches the rare
  # case where the callback misfired (worker killed between succeed
  # and cleanup_workspace!, rm_rf silently failed, etc.). Short
  # window so leaked dirs don't sit on the PVC for days.
  RETAIN_AFTER_SUCCESS_OR_CANCEL = 2.hours

  # Failed workflows: keep workspace on disk so the operator can use
  # "Retry from failed step" and resume from the last committed state.
  # WorkflowWorkspacePruneJob eventually sweeps these once the retry
  # window expires.
  RETAIN_AFTER_FAILURE = 7.days

  RETAIN_CHAT_WORKSPACES = 7.days

  def perform
    db_sweep
    filesystem_sweep
    chat_workspace_sweep
  end

  private

  def db_sweep
    n = 0

    # Succeeded + cancelled: short backstop retention.
    sc_cutoff = RETAIN_AFTER_SUCCESS_OR_CANCEL.ago
    Workflow.where(state: %w[ succeeded cancelled ])
            .where(cleaned_up_at: nil)
            .where("finished_at IS NOT NULL AND finished_at < ?", sc_cutoff)
            .find_each do |wf|
      WorkflowWorkspace.cleanup_for(wf)
      n += 1
    end

    # Failed: longer retention for the retry UI.
    f_cutoff = RETAIN_AFTER_FAILURE.ago
    Workflow.where(state: "failed")
            .where(cleaned_up_at: nil)
            .where("finished_at IS NOT NULL AND finished_at < ?", f_cutoff)
            .find_each do |wf|
      WorkflowWorkspace.cleanup_for(wf)
      n += 1

      job = wf.job
      if job.closed? && job.branch_name.present? && job.branch_deleted_at.nil?
        begin
          deleted = GithubClient.for(repository: job.repository, user: job.user)
                                .delete_branch(job.repository.slug, job.branch_name)
          job.update_column(:branch_deleted_at, Time.current) if deleted
        rescue => e
          Rails.logger.warn("[WorkflowWorkspacePrune] failed to delete branch #{job.repository.slug}@#{job.branch_name}: #{e.class}: #{e.message}")
        end
      end
    end

    Rails.logger.info("[WorkflowWorkspacePrune] db_sweep cleaned #{n} workflow workspaces") if n > 0
  end

  # Walk $SYRUS_DATA_ROOT/workflows/ and remove any directory whose
  # Workflow is terminal and past the applicable retention window, or
  # whose Workflow no longer exists in the DB at all (orphaned clone
  # left by a hard-killed worker). Defense-in-depth: catches leaks
  # even when cleaned_up_at was incorrectly set or the DB query
  # missed something.
  def filesystem_sweep
    root = WorkflowWorkspace.data_root.join("workflows")
    return unless root.exist?

    n = 0
    root.each_child do |child|
      next unless child.directory?
      id = Integer(child.basename.to_s) rescue next

      wf = Workflow.find_by(id: id)

      if wf.nil?
        # No DB record — the workflow was destroyed; remove the orphan.
        FileUtils.rm_rf(child.to_s)
        n += 1
        next
      end

      next unless wf.terminal?
      next unless wf.finished_at

      retention = (wf.succeeded? || wf.cancelled?) ? RETAIN_AFTER_SUCCESS_OR_CANCEL : RETAIN_AFTER_FAILURE
      next unless wf.finished_at < retention.ago

      WorkflowWorkspace.cleanup_for(wf)
      n += 1
    rescue StandardError => e
      Rails.logger.warn("[WorkflowWorkspacePrune] filesystem_sweep error on #{child}: #{e.class}: #{e.message}")
    end

    Rails.logger.info("[WorkflowWorkspacePrune] filesystem_sweep removed #{n} orphaned workflow dirs") if n > 0
  end

  def chat_workspace_sweep
    n = ChatWorkspace.prune_idle!(older_than: RETAIN_CHAT_WORKSPACES)
    Rails.logger.info("[WorkflowWorkspacePrune] chat_workspace_sweep removed #{n} chat workspaces") if n > 0

    # Orphan sweep: chat-workspaces/<id> and agent_homes/chats/<id>
    # directories whose ChatSession no longer exists. Heals leaks from
    # deletions that ran on a pod without the workspace PVC (and the
    # era when agent homes were never cleaned at all).
    orphans = ChatWorkspace.sweep_orphans!
    Rails.logger.info("[WorkflowWorkspacePrune] chat_workspace_sweep removed #{orphans} orphaned chat directories") if orphans > 0
  end
end
