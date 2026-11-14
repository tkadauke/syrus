class Coworkers::ChatBranchCleanup
  def self.call(...) = new(...).call

  def initialize(link, remote: nil)
    @link = link
    @coworker = link.coworker
    @branch = "coworkers/chat/#{@coworker.id}-#{link.chat_session_id}"
    @remote = remote || remote_for(@coworker)
  end

  def call
    return :retained if @link.unsaved_workspace?
    return :retained if Coworkers::WorkspaceConflict.unresolved.exists?(
      chat_session_id: @link.chat_session_id, source_branch: @branch
    )

    sha = @remote.branch_sha(@branch)
    return :absent unless sha

    @remote.guarded_delete_if_matches!(@branch, expected_sha: sha,
      guard: Coworkers::PushGuard.new(coworker: @coworker))
    :deleted
  rescue Coworkers::RemoteWorkspace::RefChanged
    :retained
  end

  private

  def remote_for(coworker)
    match = coworker.workspace_repo.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\z}i)
    Coworkers::RemoteWorkspace.new(owner: match[1], name: match[2], user: coworker.owner_user)
  end
end
