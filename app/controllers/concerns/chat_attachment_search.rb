# Attachment-search helpers extracted from Api::V1::App::ChatsController.
#
# These build the "attach a Repository/Job/Document/Epic to a chat" search
# results: normalizing the requested type, resolving the base scope, applying
# the text filter, and serializing candidates. They are pure controller
# helpers (they read `params` and `Current.user`), so they mix straight back
# into the controller with no behavior change. Kept private on include.
module ChatAttachmentSearch
  private

  def attachment_search_results(chat_session)
    type = normalized_search_type
    scope = attachment_search_scope(type)
    return [] unless scope

    query = params[:attachment_query].to_s.strip
    scope = filter_attachment_scope(scope, type, query) if query.present?
    attached_ids = chat_session.chat_attachments.where(attachable_type: type).select(:attachable_id)
    scope.where.not(id: attached_ids).limit(10).to_a
  end

  def normalized_search_type
    raw = params[:attachment_type].presence || params[:attachable_type].presence || "Repository"
    %w[Document RepositoryDocument].include?(raw.to_s) ? "Document" : raw.to_s
  end

  ATTACHMENT_SEARCH_SCOPE_METHODS = {
    "Repository" => :repository_attachment_search_scope,
    "Job"        => :job_attachment_search_scope,
    "Document"   => :document_attachment_search_scope,
    "Epic"       => :epic_attachment_search_scope
  }.freeze

  ATTACHMENT_FILTER_SCOPE_METHODS = {
    "Repository" => :filter_repository_attachment_scope,
    "Job"        => :filter_job_attachment_scope,
    "Document"   => :filter_titled_attachment_scope,
    "Epic"       => :filter_titled_attachment_scope
  }.freeze

  def attachment_search_scope(type)
    method_name = ATTACHMENT_SEARCH_SCOPE_METHODS[type]
    send(method_name) if method_name
  end

  def repository_attachment_search_scope
    Current.user.repositories.active.order(:owner, :name, :id)
  end

  INFRA_JOB_KINDS = %w[main_grader agent_insight].freeze

  def job_attachment_search_scope
    Current.user.jobs
      .where.not(kind: INFRA_JOB_KINDS)
      .includes(:repository)
      .order(created_at: :desc, id: :desc)
  end

  def document_attachment_search_scope
    Document.where(user: Current.user, attachable_type: "Repository").includes(:attachable).order(:title, :id)
  end

  def epic_attachment_search_scope
    Current.user.epics.includes(:repository).order(:id)
  end

  def filter_attachment_scope(scope, type, query)
    method_name = ATTACHMENT_FILTER_SCOPE_METHODS[type]
    method_name ? send(method_name, scope, query) : scope
  end

  def filter_repository_attachment_scope(scope, query)
    like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    scope.where("owner LIKE ? OR name LIKE ?", like, like)
  end

  def filter_job_attachment_scope(scope, query)
    like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    id = Integer(query, exception: false)
    id ? scope.where("issue_title LIKE ? OR issue_body LIKE ? OR jobs.id = ?", like, like, id) : scope.where("issue_title LIKE ? OR issue_body LIKE ?", like, like)
  end

  def filter_titled_attachment_scope(scope, query)
    like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    scope.where("title LIKE ?", like)
  end

  def attachable_result_json(record)
    {
      type: record.is_a?(Document) ? "Document" : record.class.name,
      id: record.id,
      label: attachment_label(record)
    }
  end
end
