class Coworkers::BranchLifecycle
  def initialize(coworker, remote: nil)
    @coworker = coworker
    @remote = remote || remote_workspace
  end

  def rename!(old_handle:, new_handle:)
    move!(from: "coworkers/#{old_handle}", to: "coworkers/#{new_handle}") { yield }
  end

  def archive!(handle:)
    date = Time.current.to_date.iso8601
    base = "coworkers/archived/#{handle}-#{date}"
    move!(from: "coworkers/#{handle}", to: available_archive_branch(base)) { yield }
  end

  private

  def available_archive_branch(base)
    return base unless @remote.branch_exists?(base)

    sequence = 2
    sequence += 1 while @remote.branch_exists?("#{base}-#{sequence}")
    "#{base}-#{sequence}"
  end

  def move!(from:, to:)
    @remote.copy!(from: from, to: to, coworker: @coworker)
    begin
      result = yield
      @remote.delete!(from, coworker: @coworker, home_branch: from)
      result
    rescue StandardError # Preserve the old ref and database state as one failed operation.
      @remote.delete!(to, coworker: @coworker, home_branch: to)
      raise
    end
  end

  def remote_workspace
    match = @coworker.workspace_repo.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\z}i)
    raise ArgumentError, "invalid coworker workspace repository" unless match

    Coworkers::RemoteWorkspace.new(owner: match[1], name: match[2], user: @coworker.owner_user)
  end
end
