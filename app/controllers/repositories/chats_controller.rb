class Repositories::ChatsController < ApplicationController
  CHAT_TEMPLATES = {
    "docs_maintenance" => ChatTemplates::DocsMaintenance
  }.freeze

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
    template = chat_template
    text = template&.user_message || message_text
    if text.blank?
      redirect_to repository_chats_path(@repository, new_chat: "1")
      return
    end

    chat_session = nil
    user_message = nil
    ApplicationRecord.transaction do
      chat_session = @repository.chat_sessions.create!(
        user: Current.user,
        title: template&.title || text.truncate(80),
        last_message_at: Time.current
      )
      if template&.system_message.present?
        chat_session.messages.create!(role: "system", content: { "text" => template.system_message })
      end
      user_message = chat_session.messages.create!(role: "user", content: { "text" => text })
    end

    ChatTurnJob.perform_later(chat_session.id, user_message.id)
    redirect_to repository_chats_path(@repository), notice: "Message sent."
  end

  def triage
    text = ChatTemplates::Triage.new(repository: @repository, target: params[:target]).to_s
    chat_session = nil
    user_message = nil
    ApplicationRecord.transaction do
      chat_session = @repository.chat_sessions.create!(
        user: Current.user,
        title: "Triage open #{params[:target] == 'prs' ? 'PRs' : 'issues'}",
        last_message_at: Time.current
      )
      user_message = chat_session.messages.create!(role: "user", content: { "text" => text })
    end

    ChatTurnJob.perform_later(chat_session.id, user_message.id)
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
    broadcast_controls_update
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
    result = @pending_action.confirm!(user: Current.user)
    if result
      notice = result.respond_to?(:label) ? "Recurring task scheduled: #{result.label}." : "Pending action confirmed."
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
    result = if @pending_action.action_type == "schedule_recurring"
      @pending_action.cancel!(user: Current.user)
    else
      @pending_action.reject!
    end

    if result
      redirect_to repository_chats_path(@repository), notice: "Pending action cancelled."
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
    template_text.presence || params.dig(:chat_message, :text).to_s.strip
  end

  def template_text
    template_key = params[:chat_template].to_s
    return "" if template_key.blank?

    CHAT_TEMPLATES.fetch(template_key).new(repository: @repository).to_s.strip
  rescue KeyError
    ""
  end

  def broadcast_controls_update
    Turbo::StreamsChannel.broadcast_replace_later_to(
      "chat_session_#{@chat_session.id}_controls",
      target: "chat_session_#{@chat_session.id}_controls",
      partial: "repositories/chats/compose",
      locals: {
        repository: @repository,
        chat_session: @chat_session,
        turn_in_flight: @chat_session.turn_in_flight?
      }
    )
  end

  def chat_template
    case params[:chat_template].to_s
    when "walkthrough"
      ChatTemplates::Walkthrough.new(repository: @repository)
    end
  end
end
