class ChatStopReconciler
  TERMINAL_MESSAGE = "Cancelled by operator."

  def self.reconcile!(...)
    new(...).reconcile!
  end

  def self.reconcile_spawned_process!(spawned_process, finished_at: Time.current)
    return false unless spawned_process&.kind == "agent"
    return false if spawned_process.workdir.blank?

    chat = chat_session_for_workdir(spawned_process.workdir)
    return false unless chat

    reconcile!(
      chat_session: chat,
      spawned_process: spawned_process,
      stop_requested_before: finished_at
    )
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
  private_class_method :chat_session_for_workdir, :chat_session_from_default_workdir

  def initialize(chat_session:, spawned_process: nil, stop_requested_before: nil, message: TERMINAL_MESSAGE)
    @chat_session = chat_session
    @spawned_process = spawned_process
    @stop_requested_before = stop_requested_before
    @message = message
  end

  def reconcile!
    changed = false

    ApplicationRecord.transaction do
      chat = ChatSession.lock.find(@chat_session.id)
      return false unless reconcile_stop_request?(chat)
      return false if live_agent_process?(chat)

      create_terminal_message!(chat) if chat.turn_in_flight?
      chat.update!(stop_requested_at: nil)
      changed = true
    end

    @chat_session.reload
    @chat_session.broadcast_controls
    @chat_session.broadcast_app_header_update
    ChatQueuedMessagePromoter.deliver_one_if_idle!(@chat_session)
    changed
  end

  private

  def reconcile_stop_request?(chat)
    return false unless chat.stop_requested_at
    return false if @stop_requested_before && chat.stop_requested_at > @stop_requested_before
    return false if newer_turn_than_spawned_process?(chat)

    true
  end

  def newer_turn_than_spawned_process?(chat)
    return false unless @spawned_process

    latest_user_message = chat.messages.where(role: "user").order(:created_at, :id).last
    return false unless latest_user_message

    latest_user_message.created_at > @spawned_process.started_at
  end

  def live_agent_process?(chat)
    SpawnedProcess.running
                  .where(kind: "agent", workdir: chat.workspace_root.to_s)
                  .exists?
  end

  def create_terminal_message!(chat)
    chat.messages.create!(role: "system", content: { "text" => @message })
  end
end
