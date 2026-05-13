class Repositories::ChatsController < ApplicationController
  CHAT_TEMPLATES = {
    "docs_maintenance" => ChatTemplates::DocsMaintenance
  }.freeze

  before_action :load_repository
  before_action :load_chat_session, only: :message

  def show
    @chat_session = current_chat_session unless new_chat?
    @messages = @chat_session&.messages&.includes(:proposal)&.order(:created_at, :id) || []
    @turn_in_flight = @chat_session&.turn_in_flight? || false
  end

  def create
    text = message_text
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

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end

  def load_chat_session
    @chat_session = @repository.chat_sessions.find(params[:id])
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
end
