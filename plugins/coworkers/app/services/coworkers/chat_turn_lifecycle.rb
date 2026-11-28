class Coworkers::ChatTurnLifecycle
  include Syrus::Host::ChatTurnLifecycle

  def self.applies_to?(chat_session:, user_message:)
    Coworkers::Chat.exists?(chat_session_id: chat_session.id)
  end

  def initialize(chat_session:, user_message:)
    @chat_session = chat_session
    @user_message = user_message
  end

  def admission
    result = Coworkers::PrivilegedGrantGate.turn_admission(coworker)
    result[:message] ||= I18n.t("coworkers.confinement_unavailable", locale: @chat_session.user.locale) if result[:outcome].present?
    @environment_selection = resolve_environment_selection unless result[:outcome].present?
    result
  end

  def execution_workload_policy(policy)
    return policy unless @environment_selection

    Syrus::Host::AgentRuntime.chat_workload_policy(
      runtime_image: @environment_selection.runtime_image,
      runtime_image_digest: @environment_selection.image_digest
    )
  end

  def context = @chat_session
  def isolated_workspace? = true

  def synchronize(&block)
    Coworkers::OperationLock.with(coworker, wait: 30.minutes.to_i, &block)
  end

  private

  def coworker = Coworkers::Chat.includes(:coworker).find_by!(chat_session_id: @chat_session.id).coworker

  def resolve_environment_selection
    return unless Feature.coworker_custom_environments_enabled?
    return unless coworker.environment

    Coworkers::EnvironmentActiveSelection.resolve(coworker.environment)
  end
end
