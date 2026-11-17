class Coworkers::ChatTurnLifecycle
  include Syrus::Plugin::ChatTurnLifecycle

  def self.applies_to?(chat_session:, user_message:)
    chat_session.respond_to?(:coworker_chat) && chat_session.coworker_chat.present?
  end

  def initialize(chat_session:, user_message:)
    @chat_session = chat_session
    @user_message = user_message
  end

  def admission
    result = Coworkers::PrivilegedGrantGate.turn_admission(coworker)
    result[:message] ||= I18n.t("coworkers.confinement_unavailable", locale: @chat_session.user.locale) if result[:outcome].present?
    result
  end

  def context = @chat_session
  def isolated_workspace? = true

  def synchronize(&block)
    Coworkers::OperationLock.with(coworker, wait: 30.minutes.to_i, &block)
  end

  private

  def coworker = @chat_session.coworker_chat.coworker
end
