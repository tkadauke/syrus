class Coworkers::BranchRetentionSweep
  GRACE_PERIOD = 7.days
  MAX_DELETIONS = 50

  def self.call(...) = new(...).call

  def initialize(coworker:, remote: nil, now: Time.current, limit: MAX_DELETIONS)
    @coworker = coworker
    @remote = remote || remote_for(coworker)
    @now = now
    @limit = limit
    @guard = Coworkers::PushGuard.new(coworker:)
  end

  def call
    protected_refs = Coworkers::WorkspaceConflict.unresolved
      .where(chat_session_id: @coworker.coworker_chats.select(:chat_session_id))
      .pluck(:source_branch, :recovery_ref).flatten.compact.to_set
    entries = merged_refs
    workflow_ids = entries.to_h { |entry| [ workflow_id(entry), true ] }.keys
    existing_workflow_ids = Syrus::Host::Workflows.where(id: workflow_ids).pluck(:id).to_set
    deleted = 0
    entries.each do |entry|
      break if deleted >= @limit
      next if protected_refs.include?(entry[:branch]) || protected_refs.include?(entry[:sha])
      next unless entry[:committed_at] <= @now - GRACE_PERIOD || !existing_workflow_ids.include?(workflow_id(entry))

      @remote.guarded_delete_if_matches!(entry[:branch], expected_sha: entry[:sha], guard: @guard)
      deleted += 1
    rescue Coworkers::RemoteWorkspace::RefChanged
      next
    end
    deleted
  end

  private

  def merged_refs
    @remote.merged_run_refs(home_branch: "coworkers/#{@coworker.handle}",
      run_prefix: "coworkers/run/#{@coworker.id}-", guard: @guard)
  end

  def workflow_id(entry) = entry[:branch].split("-").last.to_i

  def remote_for(coworker)
    Coworkers::RemoteWorkspace.for_coworker(coworker)
  end
end
