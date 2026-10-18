class ChatTurnLiveness
  def self.failed_chat_turn_job_errors_for(turn_identities)
    identities = turn_identities.compact
    return {} if identities.empty?

    identity_to_chat_id = identities.to_h { |chat_id, message_id| [ [ chat_id.to_i, message_id.to_i ], chat_id ] }
    failed_chat_turn_job_rows(identities.values).each_with_object({}) do |(arguments, error), errors|
      values = job_argument_values(arguments)
      chat_id = identity_to_chat_id[values.first(2).map(&:to_i)]
      errors[chat_id] ||= normalize_error(error) if chat_id
    end
  rescue ActiveRecord::StatementInvalid, NameError
    {}
  end

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
    @latest_user_message ||= @chat_session.messages.active.where(role: "user").order(:created_at, :id).last
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

  def failed_chat_turn_job_error
    message = latest_user_message
    return unless message

    self.class.failed_chat_turn_job_errors_for(@chat_session.id => message.id)[@chat_session.id]
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

  def self.failed_chat_turn_job_rows(message_ids)
    connection = SolidQueue::Job.connection
    quoted_ids = message_ids.map { |id| connection.quote(id) }.join(", ")
    SolidQueue::FailedExecution
      .joins(:job)
      .where(solid_queue_jobs: { class_name: "ChatTurnJob", finished_at: nil })
      .where("JSON_EXTRACT(solid_queue_jobs.arguments, '$.arguments[1]') IN (#{quoted_ids})")
      .order("solid_queue_failed_executions.created_at DESC")
      .pluck("solid_queue_jobs.arguments", "solid_queue_failed_executions.error")
  end
  private_class_method :failed_chat_turn_job_rows

  def chat_turn_job_for_message?(arguments, chat_id, message_id)
    values = job_argument_values(arguments)
    return false if values.length < 2

    values[0].to_i == chat_id.to_i && values[1].to_i == message_id.to_i
  end

  def self.job_argument_values(arguments)
    payload = if arguments.respond_to?(:dig)
      arguments
    else
      JSON.parse(arguments.to_s)
    end

    Array(payload&.dig("arguments") || payload&.dig(:arguments))
  rescue JSON::ParserError
    []
  end

  def self.normalize_error(error)
    error.respond_to?(:to_h) ? error.to_h.stringify_keys : JSON.parse(error.to_s)
  rescue JSON::ParserError
    { "message" => error.to_s }
  end
  private_class_method :job_argument_values, :normalize_error

  def job_argument_values(arguments) = self.class.send(:job_argument_values, arguments)
end
