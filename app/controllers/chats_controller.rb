class ChatsController < ApplicationController
  PAGE_SIZE = 30

  before_action :load_chat_session, except: %i[ new create ]
  before_action :load_pending_action, only: %i[ confirm_pending_action destroy_pending_action ]
  before_action :load_proposal, only: %i[ confirm_proposal reject_proposal ]

  def new
    @chat_session = nil
    @messages = []
    @has_more_older = false
    @pending_actions = []
    @turn_in_flight = false
    @attachment_groups = {}
    @documents_in_scope = Document.none
    @attachment_results = []
  end

  def create
    text = message_text
    repository = repository_from_params
    chat_session = nil
    user_message = nil

    ApplicationRecord.transaction do
      chat_session = ChatSession.create!(
        user: Current.user,
        repository: repository,
        title: text.presence&.truncate(80),
        last_message_at: text.present? ? Time.current : nil
      )
      if text.present? && repository
        user_message = chat_session.messages.create!(role: "user", content: { "text" => text })
      end
    end

    ChatTurnJob.perform_later(chat_session.id, user_message.id) if user_message
    if text.present? && !repository
      redirect_to chat_path(chat_session), alert: "Attach a repository before sending a message."
    else
      redirect_to chat_path(chat_session), notice: text.present? ? "Message sent." : "Chat created."
    end
  end

  def show
    load_chat_page
  end

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
             repository: @chat_session.repository
           },
           layout: false
  end

  def message
    text = message_text
    if text.blank?
      redirect_to chat_path(@chat_session), alert: "Message cannot be blank."
      return
    end

    unless @chat_session.repository
      redirect_to chat_path(@chat_session), alert: "Attach a repository before sending a message."
      return
    end

    user_message = nil
    ApplicationRecord.transaction do
      @chat_session.update!(last_message_at: Time.current, title: @chat_session.title.presence || text.truncate(80))
      user_message = @chat_session.messages.create!(role: "user", content: { "text" => text })
    end

    ChatTurnJob.perform_later(@chat_session.id, user_message.id)
    redirect_to chat_path(@chat_session), notice: "Message sent."
  end

  def create_proposal
    unless @chat_session.repository
      redirect_to chat_path(@chat_session), alert: "Attach a repository before proposing work."
      return
    end

    proposal = ChatProposalProposer.new(
      chat_session: @chat_session,
      allowed_kinds: manual_proposal_allowed_kinds
    ).propose!(**manual_proposal_attributes)

    redirect_to chat_path(@chat_session), notice: "#{proposal.kind.humanize} proposal created."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to chat_path(@chat_session), alert: e.record.errors.full_messages.to_sentence
  rescue ArgumentError => e
    redirect_to chat_path(@chat_session), alert: e.message
  end

  def stop
    @chat_session.update!(stop_requested_at: Time.current)
    @chat_session.broadcast_controls
    redirect_to chat_path(@chat_session), notice: "Stop requested."
  end

  def refresh
    repository = @chat_session.repository
    unless repository
      redirect_to chat_path(@chat_session), alert: "Attach a repository before refreshing a workspace."
      return
    end

    ChatWorkspaceJob.perform_later(repository.id, action: :refresh)
    redirect_to chat_path(@chat_session), notice: "Repository refresh queued."
  end

  def reset
    repository = @chat_session.repository
    unless repository
      redirect_to chat_path(@chat_session), alert: "Attach a repository before resetting a workspace."
      return
    end

    ChatWorkspaceJob.perform_later(repository.id, action: :reset)
    redirect_to chat_path(@chat_session), notice: "Workspace reset queued."
  end

  def add_attachment
    attachable = attachable_from_params
    if attachable
      @chat_session.chat_attachments.find_or_create_by!(attachable: attachable)
      redirect_to chat_path(@chat_session), notice: "#{attachment_label(attachable)} attached."
    else
      redirect_to chat_path(@chat_session, attachment_type: params[:attachable_type], attachment_query: params[:attachment_query]),
                  alert: "Choose an attachment to add."
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to chat_path(@chat_session), alert: e.record.errors.full_messages.to_sentence
  end

  def destroy_attachment
    attachment = @chat_session.chat_attachments.find(params[:attachment_id])
    label = attachment_label(attachment.attachable)
    attachment.destroy!
    redirect_to chat_path(@chat_session), notice: "#{label} detached."
  end

  def confirm_pending_action
    if @pending_action.confirm!(user: Current.user)
      record = @pending_action.result
      notice =
        case record
        when ScheduledTask then "Scheduled task created: #{record.name}."
        else "Pending action confirmed."
        end
      redirect_to chat_path(@chat_session), notice: notice
    else
      redirect_to chat_path(@chat_session), alert: "Pending action is no longer active."
    end
  rescue ActiveRecord::RecordInvalid => e
    message = e.record.errors.full_messages.to_sentence.presence || "Pending action could not be confirmed."
    redirect_to chat_path(@chat_session), alert: message
  rescue ActiveRecord::RecordNotFound, ArgumentError => e
    redirect_to chat_path(@chat_session), alert: e.message
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
      redirect_to chat_path(@chat_session), notice: notice
    else
      redirect_to chat_path(@chat_session), alert: "Pending action is no longer active."
    end
  rescue ActiveRecord::RecordNotFound => e
    redirect_to chat_path(@chat_session), alert: e.message
  end

  def confirm_proposal
    if @proposal.confirmed?
      redirect_to chat_path(@chat_session), alert: "Proposal is already confirmed."
      return
    end

    unless @proposal.proposed?
      redirect_to chat_path(@chat_session), alert: "Proposal is no longer proposed."
      return
    end

    result = ChatProposalFiler.new(user: Current.user, repository: @proposal.chat_session.repository).file!([ @proposal ])
    redirect_to chat_path(@chat_session), notice: proposal_confirmed_notice(result)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to chat_path(@chat_session), alert: e.record.errors.full_messages.to_sentence
  end

  def reject_proposal
    if @proposal.proposed?
      @proposal.update!(state: "rejected", rejected_at: Time.current)
      redirect_to chat_path(@chat_session), notice: "Proposal rejected."
    else
      redirect_to chat_path(@chat_session), alert: "Proposal is no longer proposed."
    end
  end

  private

  def load_chat_session
    @chat_session = Current.user.chat_sessions.find(params[:chat_id] || params[:id])
  end

  def load_pending_action
    @pending_action = @chat_session.pending_actions.find(params[:pending_action_id])
  end

  def load_proposal
    @proposal = @chat_session.proposals.find(params[:proposal_id])
  end

  def load_chat_page
    @messages, @has_more_older = paginated_tail(@chat_session)
    @pending_actions = []
    @turn_in_flight = @chat_session.turn_in_flight?
    @attachment_groups = @chat_session.chat_attachments.includes(:attachable).order(:attachable_type, :attached_at, :id).group_by(&:attachable_type)
    @documents_in_scope = @chat_session.attached_documents_in_scope.includes(:attachable).order(:title, :id)
    @attachment_results = attachment_search_results
  end

  def paginated_tail(chat_session)
    scope = chat_session.messages.includes(:proposal)
    fetched = scope.order(created_at: :desc, id: :desc).limit(PAGE_SIZE + 1).to_a
    has_more = fetched.size > PAGE_SIZE
    [ fetched.first(PAGE_SIZE).reverse, has_more ]
  end

  def message_text
    params.dig(:chat_message, :text).to_s.strip
  end

  def manual_proposal_attributes
    permitted = params.require(:chat_proposal).permit(:slug, :title, :body, :kind, :labels, :depends_on)
    {
      slug: permitted[:slug],
      title: permitted[:title],
      body: permitted[:body],
      kind: permitted[:kind],
      labels: split_list(permitted[:labels]),
      depends_on: split_list(permitted[:depends_on])
    }
  end

  def manual_proposal_allowed_kinds
    kind = params.dig(:chat_proposal, :kind).to_s
    kind == "epic" ? %w[epic] : %w[syrus_issue]
  end

  def split_list(value)
    value.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def repository_from_params
    id = params[:repository_id].presence || params.dig(:chat_attachment, :repository_id).presence
    return unless id

    Current.user.repositories.find(id)
  end

  def attachable_from_params
    type = normalized_attachable_type
    return unless type

    id = params[:attachable_id].presence || params.dig(:chat_attachment, :attachable_id).presence
    return find_attachable_by_id(type, id) if id.present?

    attachment_search_results(type: type).first
  end

  def normalized_attachable_type
    raw = params[:attachable_type].presence || params.dig(:chat_attachment, :attachable_type).presence
    return unless raw

    type = raw.to_s == "RepositoryDocument" ? "Document" : raw.to_s
    ChatAttachment::ATTACHABLE_TYPES.include?(type) ? type : nil
  end

  def find_attachable_by_id(type, id)
    case type
    when "Repository"
      Current.user.repositories.find(id)
    when "Job"
      Current.user.jobs.find(id)
    when "Document"
      Document.where(user: Current.user, attachable_type: "Repository").find(id)
    else
      type.safe_constantize&.where(user: Current.user)&.find(id)
    end
  end

  def attachment_search_results(type: normalized_search_type)
    query = params[:attachment_query].to_s.strip
    return [] unless type

    scope = attachment_search_scope(type)
    return [] unless scope

    scope = filter_attachment_scope(scope, type, query) if query.present?
    attached_ids = @chat_session&.chat_attachments&.where(attachable_type: type)&.select(:attachable_id)
    scope = scope.where.not(id: attached_ids) if attached_ids
    scope.limit(10).to_a
  end

  def normalized_search_type
    raw = params[:attachment_type].presence || params[:attachable_type].presence || "Repository"
    raw.to_s == "RepositoryDocument" ? "Document" : raw.to_s
  end

  def attachment_search_scope(type)
    case type
    when "Repository"
      Current.user.repositories.active.order(:owner, :name, :id)
    when "Job"
      Current.user.jobs.includes(:repository).order(created_at: :desc, id: :desc)
    when "Document"
      Document.where(user: Current.user, attachable_type: "Repository").includes(:attachable).order(:title, :id)
    else
      klass = type.safe_constantize
      klass&.where(user: Current.user)&.order(:id)
    end
  end

  def filter_attachment_scope(scope, type, query)
    like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    case type
    when "Repository"
      scope.where("owner LIKE ? OR name LIKE ?", like, like)
    when "Job"
      id = Integer(query, exception: false)
      id ? scope.where("issue_title LIKE ? OR issue_body LIKE ? OR jobs.id = ?", like, like, id) : scope.where("issue_title LIKE ? OR issue_body LIKE ?", like, like)
    when "Document"
      scope.where("title LIKE ?", like)
    else
      scope
    end
  end

  def attachment_label(record)
    case record
    when Repository then record.slug
    when Job then "Job ##{record.id}"
    when Document then record.title
    else record.try(:name).presence || record.try(:title).presence || "#{record.class.name} ##{record.id}"
    end
  end

  def proposal_confirmed_notice(result)
    record = result.jobs.first || @proposal.reload.materialized_record
    case record
    when Job
      "Proposal confirmed and filed as Job ##{record.id}."
    when Epic
      "Proposal confirmed and filed as #{record.display_number}."
    else
      "Proposal confirmed."
    end
  end
end
