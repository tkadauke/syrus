# Chat JSON serializers extracted from Api::V1::App::ChatsController.
#
# Assemble the wire payloads for a chat and its parts: the full chat_payload
# (messages, proposals, pending actions, attachments), the
# bookmark / hidden-chat / pending-action / attachment-group / document JSON,
# and the unread predicate. Pure controller helpers (reading `Current.user`
# and delegating to sibling helpers like chat_json), so they mix straight
# back in with no behavior change. Kept private on include.
module ChatSerialization
  private

  def workspace_tabs_json(chat_session)
    WorkspaceTabsPayload.new(chat_session).as_json
  end

  def chat_payload(chat_session, message: nil)
    PerformanceLogging.phase("chat_payload", chat_id: chat_session.id) do
      PerformanceLogging.phase("chat_payload.preload", chat_id: chat_session.id) { preload_chat_payload_associations(chat_session) }
      messages, has_more_older = PerformanceLogging.phase("chat_payload.messages_page", chat_id: chat_session.id) { paginated_tail(chat_session) }
      repository = chat_session.repository
      attachment_groups = PerformanceLogging.phase("chat_payload.attachment_groups", chat_id: chat_session.id) { attachment_groups_for_payload(chat_session) }
      counts = PerformanceLogging.phase("chat_payload.counts", chat_id: chat_session.id) do
        chat_session_payload_counts(chat_session.id)
      end
      speech_to_text = PerformanceLogging.phase("chat_payload.speech_to_text", chat_id: chat_session.id) do
        ChatSpeechToText::Capability.for(user: Current.user).as_json
      end
      turn_in_flight = chat_session.turn_in_flight?
      agent_busy = PerformanceLogging.phase("chat_payload.agent_busy", chat_id: chat_session.id) do
        chat_session.agent_busy?
      end

      {
        message: message,
        chat: PerformanceLogging.phase("chat_payload.chat", chat_id: chat_session.id) do
          chat_json(chat_session, counts: counts, turn_in_flight: turn_in_flight, agent_busy: agent_busy)
        end,
        chat_available: Current.user.chat_available?,
        turn_in_flight: turn_in_flight,
        agent_busy: agent_busy,
        switching_provider: false,
        has_more_older: has_more_older,
        pending_proposal_count: counts.fetch(:proposed_proposals),
        messages: PerformanceLogging.phase("chat_payload.messages_json", chat_id: chat_session.id, message_count: messages.size) { messages_json(messages, repository: repository) },
        bookmarks: preload_bookmarks_in_chat_payload?(chat_session) ? PerformanceLogging.phase("chat_payload.bookmarks", chat_id: chat_session.id) { bookmarks_json(chat_session) } : [],
        recent_chats: [],
        pending_actions: PerformanceLogging.phase("chat_payload.pending_actions", chat_id: chat_session.id) { pending_actions_json(chat_session) },
        agent_questions: PerformanceLogging.phase("chat_payload.agent_questions", chat_id: chat_session.id) { chat_session.agent_questions_payload },
        queued_messages: PerformanceLogging.phase("chat_payload.queued_messages", chat_id: chat_session.id) { chat_session.queued_messages_payload },
        active_goal: PerformanceLogging.phase("chat_payload.active_goal", chat_id: chat_session.id) { chat_goal_json(visible_chat_goal(chat_session)) },
        scratchpad_items: PerformanceLogging.phase("chat_payload.scratchpad_items", chat_id: chat_session.id) { chat_session.scratchpad_items_payload },
        workspace_tabs: PerformanceLogging.phase("chat_payload.workspace_tabs", chat_id: chat_session.id) { workspace_tabs_json(chat_session) },
        attachment_groups: PerformanceLogging.phase("chat_payload.attachment_groups_json", chat_id: chat_session.id) { attachment_groups_json(attachment_groups) },
        documents_in_scope: PerformanceLogging.phase("chat_payload.documents_in_scope", chat_id: chat_session.id) { documents_in_scope_for_payload(chat_session).map { |document| document_json(document) } },
        attachment_results: PerformanceLogging.phase("chat_payload.attachment_results", chat_id: chat_session.id) { attachment_results_for_payload(chat_session).map { |record| attachable_result_json(record) } },
        paths: {
          credentials_path: "/credentials",
          repositories_path: repositories_path,
          app_messages_path: "/api/v1/app/chats/#{chat_session.id}/messages",
          app_message_path: "/api/v1/app/chats/#{chat_session.id}/message",
          app_rename_path: "/api/v1/app/chats/#{chat_session.id}/rename",
          app_delete_path: "/api/v1/app/chats/#{chat_session.id}",
          app_clear_path: "/api/v1/app/chats/#{chat_session.id}/messages",
          app_branch_path: "/api/v1/app/chats/#{chat_session.id}/branch",
          app_share_path: "/api/v1/app/chats/#{chat_session.id}/share",
          app_enqueue_message_path: "/api/v1/app/chats/#{chat_session.id}/queued_messages",
          app_scheduled_messages_path: "/api/v1/app/chats/#{chat_session.id}/scheduled_messages",
          app_stop_path: "/api/v1/app/chats/#{chat_session.id}/stop",
          app_daemon_connection_path: "/api/v1/app/chats/#{chat_session.id}/daemon_connection",
          app_switch_provider_path: "/api/v1/app/chats/#{chat_session.id}/switch_provider",
          app_bookmarks_path: "/api/v1/app/chats/#{chat_session.id}/bookmarks",
          app_bookmarks_index_path: "/api/v1/app/chats/#{chat_session.id}/bookmarks",
          app_context_path: "/api/v1/app/chats/#{chat_session.id}/context",
          app_attachments_path: "/api/v1/app/chats/#{chat_session.id}/attachments",
          app_scratchpad_reorder_path: "/api/v1/app/chats/#{chat_session.id}/scratchpad_items/reorder",
          app_speech_to_text_batch_path: "/api/v1/app/chats/#{chat_session.id}/speech_to_text",
          app_speech_to_text_stream_path: "/api/v1/app/chats/#{chat_session.id}/speech_to_text/stream",
          app_cancel_coding_checkout_path: "/api/v1/app/chats/#{chat_session.id}/coding_checkout",
          app_coding_files_path: "/api/v1/app/chats/#{chat_session.id}/coding_files",
          app_coding_commits_path: "/api/v1/app/chats/#{chat_session.id}/coding_commits",
          app_coding_file_path: "/api/v1/app/chats/#{chat_session.id}/coding_file",
          app_coding_diff_path: "/api/v1/app/chats/#{chat_session.id}/coding_diff",
          app_source_file_path: "/api/v1/app/chats/#{chat_session.id}/source_file",
          app_source_file_raw_path: "/api/v1/app/chats/#{chat_session.id}/source_file/raw"
        },
        speech_to_text: speech_to_text,
        coding_mode_enabled: Feature.coding_mode_enabled?,
        local_mode_enabled: Feature.local_mode_enabled?,
        local_tunnel_connected: Feature.local_mode_enabled? && LocalDaemonSession.connected.exists?(chat_session_id: chat_session.id)
      }.then { |payload| merge_chat_payload_contributions(payload, chat_session) }
    end
  end

  # Plugin-owned slices of the payload -- `whiteboard` (whiteboard) and
  # `preview_panels` (mockups) were built inline here until core stopped
  # needing to know those models.
  def merge_chat_payload_contributions(payload, chat_session)
    context = { params: params, ssl: request.ssl? }

    contributed = PerformanceLogging.phase("chat_payload.plugin_contributions", chat_id: chat_session.id) do
      ChatPayloadContributions.payload(chat_session: chat_session, context: context, existing_keys: payload.keys)
    end
    paths = ChatPayloadContributions.paths(chat_session: chat_session, existing_keys: payload.fetch(:paths).keys)
    # Counts live inside `chat`, beside core's own, because that is where the
    # page reads them from.
    counts = ChatPayloadContributions.counts(chat_session: chat_session, existing_keys: payload.fetch(:chat).keys)

    payload.merge(contributed).merge(
      chat: payload.fetch(:chat).merge(counts),
      paths: payload.fetch(:paths).merge(paths)
    )
  end

  def preload_bookmarks_in_chat_payload?(chat_session)
    false
  end

  def preload_chat_payload_associations(chat_session)
    ActiveRecord::Associations::Preloader.new(
      records: [ chat_session ],
      associations: [
        :user,
        :active_goal,
        { repository_attachments: :attachable }
      ]
    ).call
  end

  def visible_chat_goal(chat_session)
    chat_session.active_goal || chat_session.chat_goals.terminal.newest_first.first
  end

  def chat_goal_json(goal)
    return nil unless goal

    {
      id: goal.id,
      chat_session_id: goal.chat_session_id,
      user_id: goal.user_id,
      repository_id: goal.repository_id,
      prompt: goal.prompt,
      completion_condition: goal.completion_condition,
      mode_snapshot: goal.mode_snapshot || {},
      status: goal.status,
      approval_policy: goal.approval_policy,
      auto_file_proposals: goal.auto_file_proposals?,
      auto_submit_jobs: goal.auto_submit_jobs?,
      iteration_count: goal.iteration_count.to_i,
      terminal_at: goal.terminal_at&.iso8601,
      terminal_reason: goal.terminal_reason,
      terminal_details: goal.terminal_details,
      created_at: goal.created_at.iso8601,
      updated_at: goal.updated_at.iso8601
    }
  end

  def attachment_groups_for_payload(chat_session)
    chat_session.chat_attachments.includes(:attachable).order(:attachable_type, :attached_at, :id).group_by(&:attachable_type)
  end

  def documents_in_scope_for_payload(chat_session)
    return Document.none unless include_context_in_chat_payload?

    chat_session.attached_documents_in_scope.includes(:attachable).order(:title, :id)
  end

  def attachment_results_for_payload(chat_session)
    return [] unless attachment_search_requested?

    attachment_search_results(chat_session)
  end

  def include_context_in_chat_payload?
    params[:include_context].present?
  end

  def attachment_search_requested?
    params[:attachment_type].present? || params[:attachable_type].present? || params[:attachment_query].present?
  end

  def bookmarks_json(chat_session)
    message_rows = bookmark_message_rows(chat_session.id)
    return [] if message_rows.empty?

    message_positions = {}
    message_roles = {}
    message_ids = []
    message_rows.each_with_index do |(id, role), index|
      message_ids << id
      message_roles[id] = role
      message_positions[id] = index
    end

    rows = ChatBookmark
      .where(chat_message_id: message_ids)
      .order(:chat_message_id, :id)
      .pluck(
        "chat_bookmarks.id",
        "chat_bookmarks.label",
        "chat_bookmarks.chat_message_id"
      )
      .sort_by { |id, _label, chat_message_id| [ message_positions.fetch(chat_message_id), id ] }
    anchor_resolver = bookmark_anchor_resolver(chat_session.id, rows)

    rows.map do |id, label, chat_message_id|
      {
        id: id,
        label: label,
        chat_message_id: chat_message_id,
        anchor_message_id: anchor_resolver.call(chat_message_id, message_roles[chat_message_id])
      }
    end
  end

  def bookmark_message_rows(chat_session_id)
    ChatMessage
      .active
      .where(chat_session_id: chat_session_id)
      .order(:created_at, :id)
      .pluck(:id, :role)
  end

  def pin_json(pin)
    {
      id: pin.id,
      chat_message_id: pin.chat_message_id,
      text: pin.chat_message.preview_text,
      role: pin.chat_message.role,
      created_at: pin.created_at.iso8601
    }
  end

  def pins_json(chat_session)
    ChatMessagePin
      .joins(:chat_message)
      .where(chat_messages: { chat_session_id: chat_session.id, deleted_at: nil })
      .order("chat_message_pins.created_at", "chat_message_pins.id")
      .includes(:chat_message)
      .map { |pin| pin_json(pin) }
  end

  def bookmark_anchor_resolver(chat_session_id, rows)
    return ->(chat_message_id, _role) { chat_message_id } if rows.empty?

    renderable_ids = bookmark_anchor_message_scope(chat_session_id)
      .where(role: %w[user assistant])
      .order(:id)
      .pluck(:id)

    lambda do |chat_message_id, role|
      next chat_message_id if role.in?(%w[user assistant])

      next_id = renderable_ids.bsearch { |id| id > chat_message_id }
      next_id || previous_renderable_id(renderable_ids, chat_message_id) || chat_message_id
    end
  end

  def previous_renderable_id(renderable_ids, chat_message_id)
    index = renderable_ids.bsearch_index { |id| id >= chat_message_id }
    return renderable_ids.last unless index
    return if index.zero?

    renderable_ids[index - 1]
  end

  def bookmark_anchor_message_scope(chat_session_id)
    scope = ChatMessage.active.where(chat_session_id: chat_session_id)
    return scope unless ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")

    scope.from(Arel.sql("#{ChatMessage.quoted_table_name} FORCE INDEX (idx_chat_messages_active_tail)"))
  end

  def hidden_chat_json(chat_session, context: nil)
    chat_index_json(chat_session, context: context).merge(
      hidden_at: chat_session.hidden_at&.iso8601,
      app_unhide_path: "/api/v1/app/chats/#{chat_session.id}/unhide"
    )
  end

  def chat_unread?(chat_session)
    last_read_at = current_participant_for(chat_session)&.last_read_at || chat_session.last_read_at
    chat_session.last_message_at.present? &&
      (last_read_at.blank? || chat_session.last_message_at > last_read_at)
  end

  def current_participant_for(chat_session)
    chat_session.chat_participants.detect { |participant| participant.user_id == Current.user.id } ||
      chat_session.chat_participants.find_by(user_id: Current.user.id)
  end

  def pending_actions_json(chat_session)
    ChatPendingAction.repair_tool_call_anchors_for!(chat_session)
    chat_session.association(:pending_actions).reset

    pending_actions_for_payload(chat_session).map do |action|
      {
        id: action.id,
        label: pending_action_label(action),
        detail: pending_action_detail(action),
        state: action.state,
        action: action.action,
        action_type: action.action_type,
        execution_status: action.execution_status,
        execution_step: action.execution_step,
        execution_error: action.execution_error,
        chat_message_id: action.anchor_message&.id,
        app_confirm_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}/confirm",
        app_reject_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}/reject",
        app_cancel_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}"
      }.tap do |payload|
        payload[:reason] = action.reason if action.reason.present?
        payload[:before_snapshot] = action.before_snapshot if action.before_snapshot.present?
        payload[:after_snapshot] = action.after_snapshot if action.after_snapshot.present?
        resource = pending_action_resource(action)
        payload.merge!(resource) if resource
      end
    end
  end

  def pending_actions_for_payload(chat_session)
    base_scope = chat_session.pending_actions.includes(:tool_call_message, :message)
    active_scope = base_scope.where(state: %w[queued pending confirming failed])
    recent_confirmed_scope = base_scope.where(state: "confirmed").where("confirmed_at >= ?", ChatPendingAction::CONFIRMED_VISIBLE_FOR.ago)

    active_scope.or(recent_confirmed_scope).order(:created_at, :id)
  end

  # Mirrors App::ChatMessagePayload#pending_action_json's resource case: kept
  # in sync deliberately (see ChatPendingAction::JOB_RESOURCE_ACTIONS) so the
  # live/unanchored pending-actions list shows the same target link as the
  # message-anchored card once a pending action gets anchored to a tool call.
  def pending_action_resource(action)
    payload = action.payload || {}

    case action.action
    when *ChatPendingAction::JOB_RESOURCE_ACTIONS
      job = pending_action_scoped_job(action, payload["job_id"])
      return nil unless job

      { resource_title: job.issue_title, resource_url: job_path(job) }
    when "restack_epic"
      epic = pending_action_scoped_epic(action, payload["epic_id"])
      return nil unless epic

      { resource_title: epic.title, resource_url: epic_path(epic) }
    when "reopen_epic_and_attach_job"
      return nil unless action.repository

      epic = action.repository.epics.find_by(id: payload["epic_id"])
      return nil unless epic

      { resource_title: epic.title, resource_url: epic_path(epic) }
    when "create_repo_document", "delete_repo_document"
      document = Document.find_by(id: payload["document_id"])
      return nil unless document

      { resource_title: document.title }
    when "submit_coding_changes"
      repository = action.user.repositories.active.find_by(id: payload["repository_id"])
      return nil unless repository

      { resource_title: repository.slug, resource_url: repository_path(repository) }
    end
  end

  def pending_action_scoped_job(action, id)
    id = id.to_i
    return nil if id <= 0

    scope = action.user.admin? ? Job.all : action.user.jobs
    scope.find_by(id: id)
  end

  def pending_action_scoped_epic(action, id)
    id = id.to_i
    return nil if id <= 0

    scope = action.user.admin? ? Epic.all : action.user.epics
    scope.find_by(id: id)
  end

  def attachment_groups_json(groups)
    {
      repositories: attachment_group_json(groups["Repository"]),
      epics: attachment_group_json(groups["Epic"]),
      jobs: attachment_group_json(groups["Job"]),
      documents: attachment_group_json(groups["Document"])
    }
  end

  def attachment_group_json(attachments)
    Array(attachments).map do |attachment|
      {
        id: attachment.id,
        label: attachment_label(attachment.attachable),
        app_detach_path: "/api/v1/app/chats/#{attachment.chat_session_id}/attachments/#{attachment.id}"
      }
    end
  end

  def document_json(document)
    {
      id: document.id,
      title: document.title,
      repository_slug: document.repository&.slug
    }
  end
end
