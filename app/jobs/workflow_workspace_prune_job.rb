class WorkflowWorkspacePruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

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

  # Recurring (no args): the coordinator runs the cluster-wide DB/branch and
  # chat sweeps, then fans the local-disk filesystem sweep out to every live
  # worker — each worker's workspaces live on its own local disk, so a single
  # pod can't sweep them all. `mode == "filesystem"` is the per-worker leg,
  # enqueued to that pod's resume queue (see fan_out_filesystem_prune). Passing
  # an arg also bypasses SkipIfPending's no-arg dedup, so the fan-out isn't
  # collapsed into one.
  def perform(mode = nil)
    if mode == "filesystem"
      filesystem_sweep
      return
    end

    db_sweep
    chat_workspace_sweep
    fan_out_filesystem_prune
  end

  private

  def fan_out_filesystem_prune
    hostnames = InstanceVersion.fresh.where(role: "worker").distinct.pluck(:hostname)

    # No tracked worker pods (single-host / dev): sweep the local disk directly.
    if hostnames.empty?
      filesystem_sweep
      return
    end

    hostnames.each do |host|
      self.class.set(queue: Workflow.resume_queue_name(host)).perform_later("filesystem")
    end
  end

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

    # Failed infrastructure workflows: same short backstop as succeeded/cancelled.
    # These are never operator-retried so there is no reason to hold their workspace
    # for the full retry window. The fail event should have already cleaned up
    # immediately; this sweeps any that slipped through (e.g. worker killed
    # between the state transition and the cleanup call).
    infra_cutoff = RETAIN_AFTER_SUCCESS_OR_CANCEL.ago
    Workflow.where(state: "failed")
            .where(trigger_kind: Workflow::INFRASTRUCTURE_TRIGGER_KINDS)
            .where(cleaned_up_at: nil)
            .where("finished_at IS NOT NULL AND finished_at < ?", infra_cutoff)
            .find_each do |wf|
      WorkflowWorkspace.cleanup_for(wf)
      n += 1
    end

    # Failed non-infrastructure: two tiers based on whether this is the
    # Job's latest workflow.
    #
    # Non-latest: the operator can no longer retry this workflow (reopen is
    # blocked by latest_for_job?). The eager sweep in
    # WorkflowWorkspace#setup should have cleaned these already; this is
    # the backstop for cases where no successor workflow ever started (e.g.
    # the Job was closed before a retry).
    #
    # Latest + job closed: no retry is coming. Short window, same as
    # succeeded/cancelled.
    #
    # Latest + job open: operator may retry. Keep up to RETAIN_AFTER_FAILURE
    # as a backstop.
    Workflow.where(state: "failed")
            .where.not(trigger_kind: Workflow::INFRASTRUCTURE_TRIGGER_KINDS)
            .where(cleaned_up_at: nil)
            .where("finished_at IS NOT NULL")
            .find_each do |wf|
      job = wf.job
      is_latest = job.workflows.maximum(:id) == wf.id

      if !is_latest
        WorkflowWorkspace.cleanup_for(wf)
        n += 1
      elsif job.closed?
        next unless wf.finished_at < RETAIN_AFTER_SUCCESS_OR_CANCEL.ago
        WorkflowWorkspace.cleanup_for(wf)
        n += 1
        if job.branch_name.present? && job.branch_deleted_at.nil?
          begin
            deleted = GithubClient.for(repository: job.repository, user: job.user)
                                  .delete_branch(job.repository.slug, job.branch_name)
            job.update_column(:branch_deleted_at, Time.current) if deleted
          rescue => e
            Rails.logger.warn("[WorkflowWorkspacePrune] failed to delete branch #{job.repository.slug}@#{job.branch_name}: #{e.class}: #{e.message}")
          end
        end
      else
        next unless wf.finished_at < RETAIN_AFTER_FAILURE.ago
        WorkflowWorkspace.cleanup_for(wf)
        n += 1
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

      retention = if wf.succeeded? || wf.cancelled? || wf.infrastructure_workflow?
        RETAIN_AFTER_SUCCESS_OR_CANCEL
      elsif wf.failed?
        job = wf.job
        if job.workflows.maximum(:id) != wf.id
          0.seconds
        elsif job.closed?
          RETAIN_AFTER_SUCCESS_OR_CANCEL
        else
          RETAIN_AFTER_FAILURE
        end
      else
        RETAIN_AFTER_FAILURE
      end
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

    # Coding-Mode checkouts are the expensive tier (writable clone + deps).
    # Reclaim idle ones (backing up any work to the remote first), then enforce
    # the instance-wide byte budget by LRU-evicting the rest.
    idle = ChatWorkspace.reclaim_idle_coding_checkouts!(older_than: ChatWorkspace::RECLAIM_IDLE_CODING_AFTER)
    Rails.logger.info("[WorkflowWorkspacePrune] chat_workspace_sweep reclaimed #{idle} bytes of idle coding checkouts") if idle > 0

    over_budget = ChatWorkspace.reclaim_coding_over_budget!(budget_bytes: AppSetting.chat_coding_workspace_budget_bytes)
    Rails.logger.info("[WorkflowWorkspacePrune] chat_workspace_sweep reclaimed #{over_budget} bytes of coding checkouts over budget") if over_budget > 0

    # Orphan sweep: chat-workspaces/<id> and agent_homes/chats/<id>
    # directories whose ChatSession no longer exists. Heals leaks from
    # deletions that ran on a pod without the workspace PVC (and the
    # era when agent homes were never cleaned at all).
    orphans = ChatWorkspace.sweep_orphans!
    Rails.logger.info("[WorkflowWorkspacePrune] chat_workspace_sweep removed #{orphans} orphaned chat directories") if orphans > 0
  end
end
