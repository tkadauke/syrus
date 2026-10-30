class Coworkers::HomeBranchPersistence
  include Syrus::Plugin::ChatTurnFinalizer

  def self.after_chat_turn(chat_session:, **)
    link = Coworkers::Chat.includes(:coworker).find_by(chat_session_id: chat_session.id)
    return unless link

    new(chat_session, link.coworker).persist!
  end

  def initialize(chat_session, coworker, git: GitRunner.new)
    @chat_session = chat_session
    @coworker = coworker
    @git = git
  end

  def persist!
    repository = @chat_session.repository
    path = ChatWorkspace.repo_path_for(@chat_session, repository)
    return unless ChatWorkspace.uncommitted_changes?(path)

    @git.configure_author(Coworkers::GitIdentity.new(name: @coworker.name, handle: @coworker.handle), chdir: path.to_s)
    @git.run("add", "--all", chdir: path.to_s)
    @git.run("commit", "-m", "Update @#{@coworker.handle}'s workspace", "--no-verify", chdir: path.to_s)
    @git.run(
      "push", repository.authenticated_url(user: @chat_session.user),
      "HEAD:refs/heads/coworkers/#{@coworker.handle}", chdir: path.to_s,
      env: { "GIT_TERMINAL_PROMPT" => "0" }
    )
  end
end
