class ChatTurnLiveness
  def self.chat_session_for_workdir(workdir)
    ChatSession.find_by(workspace_path: workdir) || chat_session_from_default_workdir(workdir)
  end

  def self.chat_session_from_default_workdir(workdir)
    path = Pathname.new(workdir.to_s)
    return unless path.basename.to_s.match?(/\A\d+\z/)
    return unless path.dirname.basename.to_s == "chat-workspaces"

    ChatSession.find_by(id: path.basename.to_s)
  end
  private_class_method :chat_session_from_default_workdir

  def initialize(chat_session)
    @chat_session = chat_session
  end

  def latest_user_message
    @latest_user_message ||= @chat_session.messages.where(role: "user").order(:created_at, :id).last
  end

  def live_agent_process?
    SpawnedProcess.live_agent
                  .where(workdir: @chat_session.workspace_root.to_s)
                  .exists?
  end

  def pending_chat_turn_job?
    message = latest_user_message
    return false unless message

    active_chat_turn_job_arguments.any? do |arguments|
      chat_turn_job_for_message?(arguments, @chat_session.id, message.id)
    end
  end

  private

  def active_chat_turn_job_arguments
    [
      SolidQueue::ReadyExecution,
      SolidQueue::ClaimedExecution,
      SolidQueue::BlockedExecution
    ].flat_map do |execution_class|
      execution_class
        .joins(:job)
        .where(solid_queue_jobs: { class_name: "ChatTurnJob", finished_at: nil })
        .pluck("solid_queue_jobs.arguments")
    rescue ActiveRecord::StatementInvalid
      []
    end
  rescue NameError
    []
  end

  def chat_turn_job_for_message?(arguments, chat_id, message_id)
    values = job_argument_values(arguments)
    return false if values.length < 2

    values[0].to_i == chat_id.to_i && values[1].to_i == message_id.to_i
  end

  def job_argument_values(arguments)
    payload = if arguments.respond_to?(:dig)
      arguments
    else
      JSON.parse(arguments.to_s)
    end

    Array(payload&.dig("arguments") || payload&.dig(:arguments))
  rescue JSON::ParserError
    []
  end
end
