class Coworkers::BranchLifecycle
  def initialize(coworker, remote: nil, date: Date.current)
    @coworker = coworker
    @remote = remote || remote_for(coworker)
    @date = date
  end

  def rename!(handle:)
    normalized = HandleRegistry.normalize(handle)
    return @coworker if normalized == @coworker.handle

    candidate = @coworker.dup
    candidate.handle = normalized
    raise ActiveRecord::RecordInvalid, candidate unless candidate.valid?

    old_handle = @coworker.handle
    old_branch = home(old_handle)
    new_branch = home(normalized)
    guard = Coworkers::PushGuard.new(coworker: @coworker)
    destination_guard = Coworkers::PushGuard.new(coworker: @coworker.dup.tap { |copy| copy.handle = normalized })

    Coworkers::OperationLock.with(@coworker) do
      ensure_idle!
      @remote.copy!(source: old_branch, destination: new_branch, guard: RenameGuard.new(guard, destination_guard))
      begin
        ApplicationRecord.transaction do
          @coworker.update_columns(handle: normalized)
          HandleRegistry.rename!(owner: @coworker, handle: normalized)
          @remote.guarded_delete!(old_branch, guard: guard)
        end
      rescue StandardError => error
        remove_compensating_ref(new_branch, destination_guard)
        @coworker.reload
        raise error
      end
    end
    @coworker.reload
  end

  def archive!
    guard = Coworkers::PushGuard.new(coworker: @coworker)
    source = home(@coworker.handle)
    Coworkers::OperationLock.with(@coworker) do
      ensure_idle!
      destination = available_archive_branch
      @remote.copy!(source:, destination:, guard: guard)
      begin
        ApplicationRecord.transaction do
          @coworker.destroy!
          @remote.guarded_delete!(source, guard: guard)
        end
      rescue StandardError => error
        remove_compensating_ref(destination, guard)
        raise error
      end
      destination
    end
  end

  private

  RenameGuard = Struct.new(:source_guard, :destination_guard) do
    def allow!(ref)
      source_guard.allow!(ref)
    rescue Coworkers::PushGuard::ForeignRef
      destination_guard.allow!(ref)
    end
  end

  def ensure_idle!
    chats = ChatSession.where(id: Coworkers::Chat.where(coworker_id: @coworker.id).select(:chat_session_id))
    raise Coworkers::OperationLock::Busy, "coworker has a turn in flight" if chats.where(turn_in_flight: true).exists?
  end

  def available_archive_branch
    base = "coworkers/archived/#{@coworker.handle}-#{@date.iso8601}"
    candidate = base
    suffix = 1
    while @remote.branch_exists?(candidate)
      suffix += 1
      candidate = "#{base}-#{suffix}"
    end
    candidate
  end

  def home(handle) = "coworkers/#{handle}"

  def remove_compensating_ref(branch, guard)
    @remote.guarded_delete!(branch, guard:) if @remote.branch_exists?(branch)
  rescue StandardError => cleanup_error
    Rails.logger.error("[Coworkers::BranchLifecycle] failed to remove compensating ref #{branch}: #{cleanup_error.message}")
  end

  def remote_for(coworker)
    match = coworker.workspace_repo.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\z}i)
    raise ArgumentError, "invalid workspace repository" unless match

    Coworkers::RemoteWorkspace.new(owner: match[1], name: match[2], user: coworker.owner_user)
  end
end
