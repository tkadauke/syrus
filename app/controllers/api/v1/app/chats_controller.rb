module Api
  module V1
    module App
      class ChatsController < BaseController
        PAGE_SIZE = ChatSession::MESSAGE_PAGE_SIZE
        CHAT_TURN_ENQUEUE_RETRY_DELAYS = [ 0.05, 0.2 ].freeze
        CHAT_STREAM_POLL_INTERVAL = 0.25.seconds
        CHAT_STREAM_TIMEOUT = 30.minutes

        def index
          render json: {
            chats: recent_chats_index_json,
            repositories: Current.user.repositories.active.order(:owner, :name).map { |repository| repository_json(repository) }
          }
        end

        def new
          render json: form_payload
        end

        def show
          render json: chat_payload(find_chat_session)
        end

        def messages
          chat_session = find_chat_session
          before_id = Integer(params[:before], exception: false)
          messages, has_more_older = paginated_before(chat_session, before_id)

          render json: {
            has_more_older: has_more_older,
            messages: messages_json(messages, repository: chat_session.repository)
          }
        end

        # Create the first-run onboarding chat: attached to the operator's
        # first active repository, flagged onboarding (so the agent gets the
        # onboarding script), and seeded with a kickoff message so the agent
        # welcomes the operator immediately.
        def onboarding
          # Idempotent: the onboarding step (and its "open chat" follow-ups)
          # should always land on the one onboarding chat, not spawn new ones.
          existing = Current.user.onboarding_chat
          if existing
            render json: { message: "Chat opened.", redirect_to: chat_path(existing), chat: chat_json(existing) }, status: :ok
            return
          end

          repository = Current.user.repositories.active.order(:owner, :name).first
          chat_session = nil
          user_message = nil

          ApplicationRecord.transaction do
            chat_session = ChatSession.create!(
              user: Current.user,
              repository: repository,
              onboarding: true,
              last_message_at: Time.current
            )
            user_message = chat_session.messages.create!(
              role: "user",
              content: { "text" => "I just finished setting up Syrus. Show me how it works and help me get started." }
            )
          end

          enqueue_chat_title(chat_session, user_message)
          enqueue_chat_turn(chat_session, user_message)

          render json: {
            message: "Chat created.",
            redirect_to: chat_path(chat_session),
            chat: chat_json(chat_session)
          }, status: :created
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::StatementTimeout, SolidQueue::Job::EnqueueError => e
          raise unless transient_chat_lock_error?(e)

          render_temporary_chat_lock_error
        end

        def create
          chat_session = create_chat_session

          render json: {
            message: chat_session.messages.exists? ? "Message sent." : "Chat created.",
            redirect_to: chat_path(chat_session),
            chat: chat_json(chat_session)
          }, status: :created
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::StatementTimeout, SolidQueue::Job::EnqueueError => e
          raise unless transient_chat_lock_error?(e)

          render_temporary_chat_lock_error
        end

        def message
          chat_session = find_chat_session
          text = message_text
          if text.blank?
            render_error("validation_failed", "Message cannot be blank.", status: :unprocessable_content)
            return
          end

          user_message = nil
          ApplicationRecord.transaction do
            chat_session.update!(
              last_message_at: Time.current,
              title: chat_session.title.presence
            )
            user_message = chat_session.messages.create!(role: "user", content: { "text" => text })
          end
          if chat_session.title.blank? && (title_message = first_user_message(chat_session))
            enqueue_chat_title(chat_session, title_message)
          end
          enqueue_chat_turn(chat_session, user_message)

          if stream_request?
            stream_chat_turn(chat_session, user_message)
            return
          end

          render json: chat_payload(chat_session.reload, message: "Message sent.")
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::StatementTimeout, SolidQueue::Job::EnqueueError => e
          raise unless transient_chat_lock_error?(e)

          render_temporary_chat_lock_error
        end

        def stop
          chat_session = find_chat_session
          chat_session.update!(stop_requested_at: Time.current)
          chat_session.broadcast_controls

          render json: chat_payload(chat_session.reload, message: "Stop requested.")
        end

        def mark_read
          find_chat_session.update!(last_read_at: Time.current)

          head :no_content
        end

        def rename
          chat_session = find_chat_session
          name = chat_name
          if name.blank?
            render_error("validation_failed", "Name cannot be blank.", status: :unprocessable_content)
            return
          end

          if name.length > ChatSession::TITLE_MAX_LENGTH
            render_error("validation_failed", "Name must be #{ChatSession::TITLE_MAX_LENGTH} characters or fewer.", status: :unprocessable_content)
            return
          end

          chat_session.update!(title: name)

          render json: chat_payload(chat_session.reload, message: "Chat renamed.")
        end

        def enqueue_message
          chat_session = find_chat_session
          text = message_text
          if text.blank?
            render_error("validation_failed", "Message cannot be blank.", status: :unprocessable_content)
            return
          end

          queued_message = chat_session.chat_queued_messages.create!(content: { "text" => text })
          notice = "Message queued."

          unless chat_session.turn_in_flight? || chat_session.agent_busy?
            user_message = promote_queued_message(chat_session, queued_message)
            enqueue_chat_title(chat_session, user_message) if chat_session.title.blank? && user_message == first_user_message(chat_session)
            enqueue_chat_turn(chat_session, user_message)
            notice = "Message sent."
          end

          render json: chat_payload(chat_session.reload, message: notice)
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::StatementTimeout, SolidQueue::Job::EnqueueError => e
          raise unless transient_chat_lock_error?(e)

          render_temporary_chat_lock_error
        end

        def update_queued_message
          chat_session = find_chat_session
          queued_message = chat_session.queued_messages.find(params[:queued_message_id])
          text = message_text
          if text.blank?
            render_error("validation_failed", "Message cannot be blank.", status: :unprocessable_content)
            return
          end

          queued_message.update!(content: { "text" => text })
          render json: chat_payload(chat_session.reload, message: "Queued message updated.")
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def destroy_queued_message
          chat_session = find_chat_session
          queued_message = chat_session.queued_messages.find(params[:queued_message_id])
          queued_message.destroy!

          render json: chat_payload(chat_session.reload, message: "Queued message deleted.")
        end

        def add_attachment
          chat_session = find_chat_session
          attachable = attachable_from_params(chat_session)
          unless attachable
            render_error("validation_failed", "Choose an attachment to add.", status: :unprocessable_content)
            return
          end

          chat_session.chat_attachments.find_or_create_by!(attachable: attachable)
          render json: chat_payload(chat_session.reload, message: "#{attachment_label(attachable)} attached.")
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def destroy_attachment
          chat_session = find_chat_session
          attachment = chat_session.chat_attachments.find(params[:attachment_id])
          label = attachment_label(attachment.attachable)
          attachment.destroy!

          render json: chat_payload(chat_session.reload, message: "#{label} detached.")
        end

        def create_bookmark
          chat_session = find_chat_session
          message = chat_session.messages.find(params[:message_id])
          bookmark = message.bookmarks.create!(label: bookmark_label, kind: "manual")

          render json: chat_payload(chat_session.reload, message: "Bookmarked #{bookmark.label}.")
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def confirm_pending_action
          chat_session = find_chat_session
          pending_action = find_pending_action(chat_session)

          if pending_action.confirm!(user: Current.user)
            render json: chat_payload(chat_session.reload, message: pending_action_confirmed_notice(pending_action))
          else
            render_error("validation_failed", "Pending action is no longer active.", status: :unprocessable_content)
          end
        rescue ActiveRecord::RecordInvalid => e
          message = e.record.errors.full_messages.to_sentence.presence || "Pending action could not be confirmed."
          render_error("validation_failed", message, status: :unprocessable_content)
        rescue ArgumentError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        def destroy_pending_action
          chat_session = find_chat_session
          pending_action = find_pending_action(chat_session)
          rejection = pending_action.action_type != "schedule_recurring"
          result = rejection ? pending_action.reject! : pending_action.cancel!(user: Current.user)

          if result
            render json: chat_payload(chat_session.reload, message: rejection ? "Pending action rejected." : "Pending action cancelled.")
          else
            render_error("validation_failed", "Pending action is no longer active.", status: :unprocessable_content)
          end
        end

        def confirm_proposal
          chat_session = find_chat_session
          proposal = find_proposal(chat_session)
          if proposal.confirmed?
            render_error("validation_failed", "Proposal is already confirmed.", status: :unprocessable_content)
            return
          end

          unless proposal.proposed?
            render_error("validation_failed", "Proposal is no longer proposed.", status: :unprocessable_content)
            return
          end

          result = if proposal.epic_bundle?
            ChatEpicProposalMaterializer.new(user: Current.user).file!(proposal)
          else
            ChatProposalFiler.new(user: Current.user, repository: proposal.effective_repository).file!([ proposal ])
          end

          chat_session.messages.create!(
            role: "system",
            content: { "text" => proposal_confirmation_text(proposal.reload, result) }
          )

          render json: chat_payload(chat_session.reload, message: proposal_confirmed_notice(proposal, result))
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue ArgumentError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        def reject_proposal
          chat_session = find_chat_session
          proposal = find_proposal(chat_session)

          if proposal.proposed?
            proposal.update!(state: "rejected", rejected_at: Time.current)
            chat_session.messages.create!(
              role: "system",
              content: { "text" => proposal_rejection_text(proposal) }
            )
            render json: chat_payload(chat_session.reload, message: "Proposal rejected.")
          else
            render_error("validation_failed", "Proposal is no longer proposed.", status: :unprocessable_content)
          end
        end

        private

        def form_payload
          {
            repositories: Current.user.repositories.active.order(:owner, :name).map { |repository| repository_json(repository) },
            repositories_path: repositories_path
          }
        end

        def chat_payload(chat_session, message: nil)
          messages, has_more_older = paginated_tail(chat_session)
          repository = chat_session.repository
          attachment_groups = chat_session.chat_attachments.includes(:attachable).order(:attachable_type, :attached_at, :id).group_by(&:attachable_type)
          whiteboard = chat_session.whiteboard
          whiteboard_scene = whiteboard ? whiteboard.current_state : Whiteboard.default_state

          {
            message: message,
            chat: chat_json(chat_session),
            chat_available: Current.user.claude_oauth_token.present?,
            turn_in_flight: chat_session.turn_in_flight?,
            agent_busy: chat_session.agent_busy?,
            has_more_older: has_more_older,
            messages: messages_json(messages, repository: repository),
            bookmarks: chat_session.bookmarks.includes(:chat_message).map { |bookmark| bookmark_json(bookmark) },
            recent_chats: recent_chats_json(chat_session),
            pending_actions: pending_actions_json(chat_session),
            queued_messages: chat_session.queued_messages_payload,
            attachment_groups: attachment_groups_json(attachment_groups),
            documents_in_scope: chat_session.attached_documents_in_scope.includes(:attachable).order(:title, :id).map { |document| document_json(document) },
            attachment_results: attachment_search_results(chat_session).map { |record| attachable_result_json(record) },
            whiteboard: {
              version: whiteboard_scene.fetch("version"),
              elements: whiteboard_scene.fetch("elements"),
              appState: whiteboard_scene.fetch("appState"),
              files: whiteboard_scene.fetch("files")
            },
            paths: {
              new_chat_path: new_chat_path,
              credentials_path: edit_credentials_path,
              repositories_path: repositories_path,
              app_messages_path: "/api/v1/app/chats/#{chat_session.id}/messages",
              app_message_path: "/api/v1/app/chats/#{chat_session.id}/message",
              app_enqueue_message_path: "/api/v1/app/chats/#{chat_session.id}/queued_messages",
              app_rename_path: "/api/v1/app/chats/#{chat_session.id}/rename",
              app_stop_path: "/api/v1/app/chats/#{chat_session.id}/stop",
              app_bookmarks_path: "/api/v1/app/chats/#{chat_session.id}/bookmarks",
              app_attachments_path: "/api/v1/app/chats/#{chat_session.id}/attachments",
              app_whiteboard_path: "/api/v1/app/chats/#{chat_session.id}/whiteboard"
            }
          }
        end

        def paginated_tail(chat_session)
          scope = message_scope(chat_session)
          fetched = scope.order(created_at: :desc, id: :desc).limit(PAGE_SIZE + 1).to_a
          has_more = fetched.size > PAGE_SIZE
          [ fetched.first(PAGE_SIZE).reverse, has_more ]
        end

        def paginated_before(chat_session, before_id)
          scope = message_scope(chat_session)
          scope = scope.where("id < ?", before_id) if before_id&.positive?
          fetched = scope.order(created_at: :desc, id: :desc).limit(PAGE_SIZE + 1).to_a
          has_more = fetched.size > PAGE_SIZE
          [ fetched.first(PAGE_SIZE).reverse, has_more ]
        end

        def message_scope(chat_session)
          chat_session.messages.includes(proposal: [ :repository, :job, :epic, :target_epic, dependencies: [], child_proposals: [ :repository, :job, dependencies: [] ] ])
        end

        def messages_json(messages, repository:)
          ::App::ChatMessagePayload.messages(messages, repository: repository)
        end

        def bookmark_json(bookmark)
          {
            id: bookmark.id,
            label: bookmark.label,
            chat_message_id: bookmark.chat_message_id,
            anchor_message_id: bookmark.anchor_message_id
          }
        end

        def recent_chats_json(current_chat_session)
          chat_ids = Current.user.chat_sessions
            .order(created_at: :desc, id: :desc)
            .limit(20)
            .pluck(:id)

          chat_ids = chat_ids.first(19) + [ current_chat_session.id ] unless chat_ids.include?(current_chat_session.id)

          Current.user.chat_sessions
            .where(id: chat_ids)
            .preload(repository_attachments: :attachable)
            .to_a
            .sort_by { |chat_session| [ chat_session.created_at, chat_session.id ] }
            .reverse
            .map do |chat_session|
            chat_json(chat_session).merge(
              current: chat_session.id == current_chat_session.id,
              last_message_at: chat_session.last_message_at&.iso8601,
              unread: chat_unread?(chat_session)
            )
          end
        end

        def recent_chats_index_json
          Current.user.chat_sessions
            .preload(repository_attachments: :attachable)
            .order(Arel.sql("COALESCE(chat_sessions.last_message_at, chat_sessions.updated_at, chat_sessions.created_at) DESC"))
            .limit(20)
            .map do |chat_session|
            chat_json(chat_session).merge(
              last_message_at: chat_session.last_message_at&.iso8601,
              unread: chat_unread?(chat_session),
              created_at: chat_session.created_at.iso8601,
              updated_at: chat_session.updated_at.iso8601
            )
          end
        end

        def chat_unread?(chat_session)
          chat_session.last_message_at.present? &&
            (chat_session.last_read_at.blank? || chat_session.last_message_at > chat_session.last_read_at)
        end

        def pending_actions_json(chat_session)
          chat_session.pending_actions.where(state: "pending").order(:created_at, :id).map do |action|
            {
              id: action.id,
              label: pending_action_label(action),
              action: action.action,
              action_type: action.action_type,
              app_confirm_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}/confirm",
              app_cancel_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}"
            }
          end
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

        def attachment_search_scope(type)
          case type
          when "Repository"
            Current.user.repositories.active.order(:owner, :name, :id)
          when "Job"
            Current.user.jobs.includes(:repository).order(created_at: :desc, id: :desc)
          when "Document"
            Document.where(user: Current.user, attachable_type: "Repository").includes(:attachable).order(:title, :id)
          when "Epic"
            Current.user.epics.includes(:repository).order(:id)
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
          when "Epic"
            scope.where("title LIKE ?", like)
          else
            scope
          end
        end

        def attachable_result_json(record)
          {
            type: record.is_a?(Document) ? "Document" : record.class.name,
            id: record.id,
            label: attachment_label(record)
          }
        end

        def create_chat_session
          text = message_text
          repository = repository_from_params
          chat_session = nil
          user_message = nil

          ApplicationRecord.transaction do
            chat_session = ChatSession.create!(
              user: Current.user,
              repository: repository,
              title: text.present? ? nil : ChatSession.fallback_title_for(repository),
              last_message_at: text.present? ? Time.current : nil
            )
            if text.present?
              user_message = chat_session.messages.create!(role: "user", content: { "text" => text })
            end
          end

          enqueue_chat_title(chat_session, user_message) if user_message
          enqueue_chat_turn(chat_session, user_message) if user_message
          chat_session
        end

        def enqueue_chat_title(chat_session, user_message)
          ChatTitleJob.perform_later(chat_session.id, user_message.id)
        end

        def first_user_message(chat_session)
          chat_session.messages.where(role: "user").order(:created_at, :id).first
        end

        def enqueue_chat_turn(chat_session, user_message)
          retry_delays = CHAT_TURN_ENQUEUE_RETRY_DELAYS.dup

          begin
            ChatTurnJob.perform_later(chat_session.id, user_message.id)
          rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::StatementTimeout, SolidQueue::Job::EnqueueError => e
            raise unless transient_chat_lock_error?(e) && retry_delays.any?

            delay = retry_delays.shift
            Rails.logger.warn("Retrying ChatTurnJob enqueue after transient database lock: #{e.class}: #{e.message}")
            sleep(delay) if delay.positive?
            retry
          end
        end

        def promote_queued_message(chat_session, queued_message)
          user_message = nil
          ApplicationRecord.transaction do
            locked_chat = ChatSession.lock.find(chat_session.id)
            locked_queued_message = locked_chat.queued_messages.find(queued_message.id)
            user_message = locked_chat.messages.create!(role: "user", content: locked_queued_message.content)
            locked_queued_message.update!(delivered_at: Time.current)
            locked_chat.update!(
              last_message_at: Time.current,
              title: locked_chat.title.presence
            )
          end
          user_message
        end

        def render_temporary_chat_lock_error
          render_error(
            "temporary_lock",
            "Chat request was blocked by a temporary database lock. Try again.",
            status: :service_unavailable
          )
        end

        def transient_chat_lock_error?(error)
          error_chain(error).any? do |candidate|
            candidate.is_a?(ActiveRecord::LockWaitTimeout) ||
              candidate.is_a?(ActiveRecord::Deadlocked) ||
              candidate.is_a?(ActiveRecord::StatementTimeout) ||
              candidate.class.name == "SQLite3::BusyException" ||
              candidate.message.match?(/SQLite3::BusyException|database is locked|LockWaitTimeout|Deadlocked|StatementTimeout/i)
          end
        end

        def error_chain(error)
          chain = []
          while error && !chain.include?(error)
            chain << error
            error = error.cause
          end
          chain
        end

        def find_chat_session
          Current.user.chat_sessions.find(params[:id])
        end

        def find_pending_action(chat_session)
          chat_session.pending_actions.find(params[:pending_action_id])
        end

        def find_proposal(chat_session)
          chat_session.proposals.find(params[:proposal_id])
        end

        def message_text
          (params[:content].presence || params.dig(:chat_message, :text)).to_s.strip
        end

        def chat_name
          (params[:name].presence || params.dig(:chat, :name).presence || params.dig(:chat, :title)).to_s.strip
        end

        def stream_request?
          request.format == Mime[:event_stream] || request.headers["Accept"].to_s.include?("text/event-stream")
        end

        def stream_chat_turn(chat_session, user_message)
          response.headers["Content-Type"] = "text/event-stream"
          response.headers["Cache-Control"] = "no-cache"
          response.headers["X-Accel-Buffering"] = "no"

          self.response_body = Enumerator.new do |stream|
            write_sse(stream, "message", { role: "user", content: user_message.content["text"].to_s, message: chat_message_json(user_message, chat_session: chat_session) })
            stream_chat_messages(stream, chat_session, after_id: user_message.id)
          rescue StandardError => e
            write_sse(stream, "error", { message: e.message })
          end
        end

        def stream_chat_messages(stream, chat_session, after_id:)
          deadline = Time.current + CHAT_STREAM_TIMEOUT
          last_seen_id = after_id
          observed_turn_response = false

          loop do
            messages = chat_session.messages
              .includes(proposal: [ :repository, :job, :epic, :target_epic, dependencies: [], child_proposals: [ :repository, dependencies: [] ] ])
              .where("id > ?", last_seen_id)
              .order(:id)
              .to_a

            messages.each do |message|
              last_seen_id = message.id
              next if message.role == "user"

              observed_turn_response = true
              write_chat_stream_message(stream, message, chat_session: chat_session)
            end

            chat_session.reload
            if observed_turn_response && !chat_session.turn_in_flight? && !chat_session.agent_busy?
              write_sse(stream, "turn_complete", { chat_id: chat_session.id })
              break
            end

            if Time.current >= deadline
              write_sse(stream, "error", { message: "Chat turn timed out while waiting for the agent response." })
              break
            end

            sleep CHAT_STREAM_POLL_INTERVAL
          end
        end

        def write_chat_stream_message(stream, message, chat_session:)
          payload = chat_message_json(message, chat_session: chat_session)
          case message.role
          when "assistant"
            write_sse(stream, "text_chunk", { content: payload[:text], message: payload })
            write_sse(stream, "proposal", { proposal: payload[:proposal], message: payload }) if payload[:proposal]
          when "system"
            write_sse(stream, "error", { message: payload[:text], message_record: payload })
          else
            write_sse(stream, "message", { message: payload })
          end
        end

        def chat_message_json(message, chat_session:)
          ::App::ChatMessagePayload.messages([ message ], repository: chat_session.repository).first
        end

        def write_sse(stream, event, data)
          stream << "event: #{event}\n"
          stream << "data: #{JSON.generate(data)}\n\n"
        end

        def bookmark_label
          params.dig(:chat_bookmark, :label).to_s.strip
        end

        def repository_from_params
          id = params[:repository_id].presence
          return unless id

          Current.user.repositories.active.find(id)
        end

        def attachable_from_params(chat_session)
          type = normalized_attachable_type
          return unless type

          id = params[:attachable_id].presence || params.dig(:chat_attachment, :attachable_id).presence
          return find_attachable_by_id(type, id) if id.present?

          attachment_search_results(chat_session).first
        end

        def normalized_attachable_type
          raw = params[:attachable_type].presence || params.dig(:chat_attachment, :attachable_type).presence
          return unless raw

          type = %w[Document RepositoryDocument].include?(raw.to_s) ? "Document" : raw.to_s
          ChatAttachment::ATTACHABLE_TYPES.include?(type) ? type : nil
        end

        def find_attachable_by_id(type, id)
          case type
          when "Repository"
            Current.user.repositories.active.find(id)
          when "Job"
            Current.user.jobs.find(id)
          when "Document"
            Document.where(user: Current.user, attachable_type: "Repository").find(id)
          when "Epic"
            Current.user.epics.find(id)
          end
        end

        def chat_json(chat_session)
          repository = chat_session.repository
          {
            id: chat_session.id,
            title: chat_session.title,
            title_pending: chat_session.title_pending?,
            chat_path: chat_path(chat_session),
            repository: repository ? repository_json(repository).merge(repository_path: repository_path(repository)) : nil,
            stop_requested_at: chat_session.stop_requested_at&.iso8601,
            cumulative_input_tokens: chat_session.cumulative_input_tokens.to_i,
            cumulative_output_tokens: chat_session.cumulative_output_tokens.to_i,
            cumulative_cost_usd: chat_session.cumulative_cost.to_f
          }
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug
          }
        end

        def attachment_label(record)
          case record
          when Repository then record.slug
          when Epic then record.display_number
          when Job then "#{::App::Presentation.job_slug(record)}: #{record.issue_title.presence || record.issue_number || record.kind}"
          when Document then "#{record.title} (#{record.repository&.slug})"
          else record.try(:name).presence || record.try(:title).presence || "#{record.class.name} ##{record.id}"
          end
        end

        def pending_action_label(action)
          payload = action.payload || {}
          case action.action
          when "add_repo_note"
            "Pin repository note"
          when "remove_repo_note"
            "Remove repository note ##{payload['id']}"
          when "cancel_job"
            "Cancel #{::App::Presentation.job_slug(payload['job_id'])}"
          when "retry_job"
            "Retry #{::App::Presentation.job_slug(payload['job_id'])}"
          when "rebase_job"
            "Rebase #{::App::Presentation.job_slug(payload['job_id'])}"
          when "submit_chat_feedback"
            "Submit feedback on #{::App::Presentation.job_slug(payload['job_id'])}"
          when "reopen_epic_and_attach_job"
            "Reopen Epic ##{payload['epic_id']} and attach #{::App::Presentation.job_slug(payload['job_id'])}"
          else
            payload["label"].presence || action.action_type.to_s.humanize
          end
        end

        def pending_action_confirmed_notice(action)
          record = action.result
          case record
          when Workflow
            if record.trigger_kind == "chat_feedback"
              "Feedback submitted. Workflow ##{record.id} has been queued."
            else
              "Pending action confirmed."
            end
          when ScheduledTask
            "Scheduled task created: #{record.name}."
          else
            "Pending action confirmed."
          end
        end

        def proposal_confirmed_notice(proposal, result)
          record = result.respond_to?(:epic) && result.epic ? result.epic : result.jobs.first || proposal.reload.materialized_record
          case record
          when Job
            "Proposal confirmed and filed as #{::App::Presentation.job_slug(record)}."
          when Epic
            "Proposal confirmed and filed as #{record.display_number}."
          else
            "Proposal confirmed."
          end
        end

        def proposal_confirmation_text(proposal, result)
          if result.respond_to?(:epic) && result.epic
            child_jobs = Array(result.jobs).map { |job| proposal_job_label(job) }.join(", ")
            text = %(Proposal confirmed. Epic ##{result.epic.id} "#{result.epic.title}" was created.)
            return child_jobs.present? ? "#{text} Child jobs: #{child_jobs}." : text
          end

          job = Array(result.respond_to?(:jobs) ? result.jobs : []).first || proposal.job
          return "Proposal confirmed. #{proposal_job_label(job)} was created." if job

          issue_number = result.github_issue_numbers[proposal.id] if result.respond_to?(:github_issue_numbers)
          issue_number ||= proposal.github_issue_number
          if issue_number
            return %(Proposal confirmed. GitHub issue ##{issue_number} "#{proposal.title}" was filed.)
          end

          %(Proposal confirmed. "#{proposal.title}" was filed.)
        end

        def proposal_rejection_text(proposal)
          %(Proposal rejected. "#{proposal.title}" was discarded.)
        end

        def proposal_job_label(job)
          %(Job ##{job.id} "#{job.issue_title}")
        end
      end
    end
  end
end
