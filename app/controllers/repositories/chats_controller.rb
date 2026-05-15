class Repositories::ChatsController < ApplicationController
  before_action :load_repository
  before_action :load_chat_session, only: %i[ message stop refresh reset ]
  before_action :load_pending_action, only: %i[ confirm_pending_action destroy_pending_action ]

  def show
    @chat_session = current_chat_session unless new_chat?
    @messages = @chat_session&.messages&.includes(:proposal)&.order(:created_at, :id) || []
    @pending_actions = @chat_session&.pending_actions&.pending&.order(:created_at, :id) || []
    @turn_in_flight = @chat_session&.turn_in_flight? || false
  end

  def create
    template = rendered_chat_template
    if template
      start_template_chat!(template)
      redirect_to repository_chats_path(@repository), notice: "Message sent."
      return
    end

    text = params.dig(:chat_message, :text).to_s.strip
    if text.blank?
      redirect_to repository_chats_path(@repository, new_chat: "1")
      return
    end

    chat_session = nil
    user_message = nil
    ApplicationRecord.transaction do
      chat_session = @repository.chat_sessions.create!(
        user: Current.user,
        title: text.truncate(80),
        last_message_at: Time.current
      )
      user_message = chat_session.messages.create!(role: "user", content: { "text" => text })
    end

    ChatTurnJob.perform_later(chat_session.id, user_message.id)
    redirect_to repository_chats_path(@repository), notice: "Message sent."
  rescue ArgumentError => e
    redirect_to repository_path(@repository), alert: e.message
  end

  def triage
    template = render_template!("triage")
    start_template_chat!(template)
    redirect_to repository_chats_path(@repository), notice: "Triage chat started."
  rescue ArgumentError => e
    redirect_to repository_path(@repository), alert: e.message
  end

  def message
    text = message_text
    if text.blank?
      redirect_to repository_chats_path(@repository), alert: "Message cannot be blank."
      return
    end

    user_message = nil
    ApplicationRecord.transaction do
      @chat_session.update!(last_message_at: Time.current)
      user_message = @chat_session.messages.create!(role: "user", content: { "text" => text })
    end

    ChatTurnJob.perform_later(@chat_session.id, user_message.id)
    redirect_to repository_chats_path(@repository), notice: "Message sent."
  end

  def stop
    @chat_session.update!(stop_requested_at: Time.current)
    @chat_session.broadcast_controls
    redirect_to repository_chats_path(@repository), notice: "Stop requested."
  end

  def refresh
    ChatWorkspaceJob.perform_later(@repository.id, action: :refresh)
    redirect_to repository_chats_path(@repository), notice: "Repository refresh queued."
  end

  def reset
    ChatWorkspaceJob.perform_later(@repository.id, action: :reset)
    redirect_to repository_chats_path(@repository), notice: "Workspace reset queued."
  end

  def confirm_pending_action
    if @pending_action.confirm!(user: Current.user)
      record = @pending_action.result
      notice = case record
               when ScheduledTask then "Scheduled task created: #{record.name}."
               else "Pending action confirmed."
               end
      redirect_to repository_chats_path(@repository), notice: notice
    else
      redirect_to repository_chats_path(@repository), alert: "Pending action is no longer active."
    end
  rescue ActiveRecord::RecordInvalid => e
    message = e.record.errors.full_messages.to_sentence.presence || "Pending action could not be confirmed."
    redirect_to repository_chats_path(@repository), alert: message
  rescue ActiveRecord::RecordNotFound, ArgumentError => e
    redirect_to repository_chats_path(@repository), alert: e.message
  end

  def destroy_pending_action
    rejection = @pending_action.action_type != "schedule_recurring"
    result = if rejection
      @pending_action.reject!
    else
      @pending_action.cancel!(user: Current.user)
    end

    if result
      notice = rejection ? "Pending action rejected." : "Pending action cancelled."
      redirect_to repository_chats_path(@repository), notice: notice
    else
      redirect_to repository_chats_path(@repository), alert: "Pending action is no longer active."
    end
  rescue ActiveRecord::RecordNotFound => e
    redirect_to repository_chats_path(@repository), alert: e.message
  end

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end

  def load_chat_session
    @chat_session = @repository.chat_sessions.find(params[:id])
  end

  def load_pending_action
    @pending_action = ChatPendingAction.where(repository: @repository, user: Current.user).find(params[:id])
  end

  def current_chat_session
    @repository.chat_sessions.order(last_message_at: :desc, created_at: :desc, id: :desc).first
  end

  def new_chat?
    ActiveModel::Type::Boolean.new.cast(params[:new_chat])
  end

  def message_text
    params.dig(:chat_message, :text).to_s.strip
  end

  def rendered_chat_template
    key = template_key
    return nil if key.blank?

    render_template!(key)
  end

  def render_template!(key)
    ChatTemplates::Registry.render(key: key, repository: @repository, params: params)
  end

  def start_template_chat!(template)
    chat_session = nil
    user_message = nil
    ApplicationRecord.transaction do
      chat_session = @repository.chat_sessions.create!(
        user: Current.user,
        title: template.title,
        last_message_at: Time.current
      )
      if template.system_message.present?
        chat_session.messages.create!(role: "system", content: { "text" => template.system_message })
      end
      user_message = chat_session.messages.create!(role: "user", content: { "text" => template.user_message })
    end

    ChatTurnJob.perform_later(chat_session.id, user_message.id)
    chat_session
  end

  def template_key
    params[:chat_template].presence || params[:template].presence
  end
end
