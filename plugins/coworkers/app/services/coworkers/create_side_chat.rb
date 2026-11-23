class Coworkers::CreateSideChat
  def self.call(coworker:, user:, repository:)
    Syrus::Host::Record.transaction do
      session = Syrus::Host::ChatSessionRecord.create!(
        user: user, repository: repository, title_auto_fallback: true,
        **coworker.chat_configuration
      )
      Coworkers::Chat.create!(coworker: coworker, chat_session: session, role: "side")
      session
    end
  end
end
