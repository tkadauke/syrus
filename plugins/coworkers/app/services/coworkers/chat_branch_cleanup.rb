class Coworkers::ChatBranchCleanup
  def self.call(...) = new(...).call

  def initialize(link, remote: nil)
    @link = link
    @coworker = link.coworker
    @branch = "coworkers/chat/#{@coworker.id}-#{link.chat_session_id}"
    @remote = remote
  end

  def call
    return :retained if @link.unsaved_workspace?
    return :retained if Coworkers::WorkspaceConflict.unresolved.exists?(
      chat_session_id: @link.chat_session_id, source_branch: @branch
    )

    sha = remote.branch_sha(@branch)
    return :absent unless sha

    remote.guarded_delete_if_matches!(@branch, expected_sha: sha,
      guard: Coworkers::PushGuard.new(coworker: @coworker))
    :deleted
  rescue Coworkers::RemoteWorkspace::RefChanged, Coworkers::RemoteWorkspace::InvalidRemote
    :retained
  end

  private

  def remote = (@remote ||= Coworkers::RemoteWorkspace.for_coworker(@coworker))
end
