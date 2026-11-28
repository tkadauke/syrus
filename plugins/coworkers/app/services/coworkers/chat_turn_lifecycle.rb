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
    unless result[:outcome].present?
      @environment_resolver = Coworkers::TurnEnvironmentSelection.new(coworker:, user_message: @user_message)
      @environment_selection = @environment_resolver.resolve
    end
    result
  rescue Coworkers::TurnEnvironmentSelection::Unavailable => error
    Rails.logger.warn("[Coworkers::ChatTurnLifecycle] environment admission blocked: #{error.message}")
    { outcome: "environment_incompatible",
      message: I18n.t("coworkers.environment_unavailable", locale: @chat_session.user.locale) }
  end

  def turn_started!
    @environment_resolver&.persist!(chat_session: @chat_session) if @environment_selection
  end

  def execution_workload_policy(policy)
    return policy unless @environment_selection

    Syrus::Host::AgentRuntime.chat_workload_policy(
      runtime_image: @environment_selection.runtime_image,
      runtime_image_digest: @environment_selection.image_digest
    )
  end

  # Only failures before an agent process exists are image launch failures.
  # Provider errors after a process started must not roll back valid images.
  def after_execution(result: nil, exception: nil)
    return unless @environment_selection
    return if @execution_reported
    return unless exception || result

    @execution_reported = true
    return if result&.success?
    return if result&.spawned_process_id.present?

    Coworkers::EnvironmentRecovery.new(coworker.environment).record_launch_failure!(
      @environment_selection.activation_id,
      reason: exception ? exception.class.name : "agent_process_not_started"
    )
  rescue StandardError => error
    Rails.logger.error("[Coworkers::ChatTurnLifecycle] launch recovery failed: #{error.class}: #{error.message}")
  end

  def context = @chat_session
  def isolated_workspace? = true

  def synchronize(&block)
    Coworkers::OperationLock.with(coworker, wait: 30.minutes.to_i, &block)
  end

  private

  def coworker = Coworkers::Chat.includes(:coworker).find_by!(chat_session_id: @chat_session.id).coworker
end
