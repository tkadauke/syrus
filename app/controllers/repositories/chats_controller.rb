class Repositories::ChatsController < ApplicationController
  PAGE_SIZE = 30

  before_action :load_repository
  before_action :load_chat_session, only: %i[ message stop refresh reset messages ]
  before_action :load_pending_action, only: %i[ confirm_pending_action destroy_pending_action ]

  def show
    @chat_available = Current.user.chat_available?
    @chat_session = current_chat_session unless new_chat?
    @messages, @has_more_older = paginated_tail(@chat_session)
    @pending_actions = @chat_session&.pending_actions&.pending&.order(:created_at, :id) || []
    @turn_in_flight = @chat_session&.turn_in_flight? || false
  end

  # Returns an HTML fragment of the next page of older messages, for
  # the infinite-scroll-up behavior in chat_controller.js. The fragment
  # is rendered without a layout so it can be parsed and prepended
  # directly into the live stream container.
  def messages
    before_id = params[:before].to_i
    fetched = @chat_session.messages.includes(:proposal)
                .where("id < ?", before_id)
                .order(created_at: :desc, id: :desc)
                .limit(PAGE_SIZE + 1)
                .to_a
    has_more = fetched.size > PAGE_SIZE
    older = fetched.first(PAGE_SIZE).reverse

    response.headers["X-Chat-Has-More-Older"] = has_more ? "true" : "false"
    render partial: "repositories/chats/message_stream",
           locals: {
             items: ChatMessageGrouper.group(older),
             repository: @repository
           },
           layout: false
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
      chat_session = ChatSession.create!(
        user: Current.user,
        repository: @repository,
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
    @chat_session = Current.user.chat_sessions.attached_to_repository(@repository).find(params[:id])
  end

  def load_pending_action
    @pending_action = ChatPendingAction.where(repository: @repository, user: Current.user).find(params[:id])
  end

  def current_chat_session
    Current.user.chat_sessions
      .attached_to_repository(@repository)
      .order(last_message_at: :desc, created_at: :desc, id: :desc)
      .first
  end

  def new_chat?
    ActiveModel::Type::Boolean.new.cast(params[:new_chat])
  end

  def message_text
    params.dig(:chat_message, :text).to_s.strip
  end

  # Loads the latest PAGE_SIZE messages in chronological order plus a
  # flag for whether older messages exist. Returns an empty pair when
  # there is no chat_session (initial empty-state render).
  def paginated_tail(chat_session)
    return [ [], false ] unless chat_session

    scope = chat_session.messages.includes(:proposal)
    fetched = scope.order(created_at: :desc, id: :desc).limit(PAGE_SIZE + 1).to_a
    has_more = fetched.size > PAGE_SIZE
    [ fetched.first(PAGE_SIZE).reverse, has_more ]
  end
end
