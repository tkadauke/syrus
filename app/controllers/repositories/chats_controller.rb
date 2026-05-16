class Repositories::ChatsController < ApplicationController
  PAGE_SIZE = 30

  before_action :load_repository
  before_action :load_chat_session, only: %i[ message stop refresh reset messages ]
  before_action :load_pending_action, only: %i[ confirm_pending_action destroy_pending_action ]
  before_action :load_proposal, only: %i[ confirm_proposal reject_proposal ]

  def show
    chat_session = if new_chat?
      ChatSession.create!(user: Current.user, repository: @repository)
    else
      current_chat_session || ChatSession.create!(user: Current.user, repository: @repository)
    end

    redirect_to chat_path(chat_session), status: :moved_permanently
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
      chat_session = ChatSession.create!(user: Current.user, repository: @repository)
      redirect_to chat_path(chat_session), notice: "Chat created."
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
    redirect_to chat_path(chat_session), notice: "Message sent."
  end

  def message
    text = message_text
    if text.blank?
      redirect_to chat_path(@chat_session), alert: "Message cannot be blank."
      return
    end

    user_message = nil
    ApplicationRecord.transaction do
      @chat_session.update!(last_message_at: Time.current)
      user_message = @chat_session.messages.create!(role: "user", content: { "text" => text })
    end

    ChatTurnJob.perform_later(@chat_session.id, user_message.id)
    redirect_to chat_path(@chat_session), notice: "Message sent."
  end

  def stop
    @chat_session.update!(stop_requested_at: Time.current)
    @chat_session.broadcast_controls
    redirect_to chat_path(@chat_session), notice: "Stop requested."
  end

  def refresh
    ChatWorkspaceJob.perform_later(@chat_session.id, action: :refresh)
    redirect_to chat_path(@chat_session), notice: "Repository refresh queued."
  end

  def reset
    ChatWorkspaceJob.perform_later(@chat_session.id, action: :reset)
    redirect_to chat_path(@chat_session), notice: "Workspace reset queued."
  end

  def confirm_pending_action
    if @pending_action.confirm!(user: Current.user)
      record = @pending_action.result
      notice = case record
               when ScheduledTask then "Scheduled task created: #{record.name}."
               else "Pending action confirmed."
               end
      redirect_to chat_path(@pending_action.chat_session), notice: notice
    else
      redirect_to chat_path(@pending_action.chat_session), alert: "Pending action is no longer active."
    end
  rescue ActiveRecord::RecordInvalid => e
    message = e.record.errors.full_messages.to_sentence.presence || "Pending action could not be confirmed."
    redirect_to chat_path(@pending_action.chat_session), alert: message
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
      redirect_to chat_path(@pending_action.chat_session), notice: notice
    else
      redirect_to chat_path(@pending_action.chat_session), alert: "Pending action is no longer active."
    end
  rescue ActiveRecord::RecordNotFound => e
    redirect_to repository_chats_path(@repository), alert: e.message
  end

  def confirm_proposal
    if @proposal.confirmed?
      redirect_to chat_path(@proposal.chat_session), alert: "Proposal is already confirmed."
      return
    end

    unless @proposal.proposed?
      redirect_to chat_path(@proposal.chat_session), alert: "Proposal is no longer proposed."
      return
    end

    result = ChatProposalFiler.new(user: Current.user, repository: @repository).file!([ @proposal ])
    record = result.jobs.first || @proposal.reload.materialized_record
    notice = record.is_a?(Job) ? "Proposal confirmed and filed as Job ##{record.id}." : "Proposal confirmed."
    redirect_to chat_path(@proposal.chat_session), notice: notice
  rescue ActiveRecord::RecordInvalid => e
    redirect_to chat_path(@proposal.chat_session), alert: e.record.errors.full_messages.to_sentence
  end

  def reject_proposal
    if @proposal.proposed?
      @proposal.update!(state: "rejected", rejected_at: Time.current)
      redirect_to chat_path(@proposal.chat_session), notice: "Proposal rejected."
    else
      redirect_to chat_path(@proposal.chat_session), alert: "Proposal is no longer proposed."
    end
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

  def load_proposal
    @proposal = proposals_scope.find(params[:proposal_id])
  end

  def proposals_scope
    ChatProposal
      .joins(chat_session: :chat_attachments)
      .where(chat_attachments: { attachable_type: "Repository", attachable_id: @repository.id })
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
