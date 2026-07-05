module Api
  module V1
    module App
      class ChatsController < BaseController
        PAGE_SIZE = ChatSession::MESSAGE_PAGE_SIZE
        CHAT_INDEX_GROUP_SIZE = 5
        HIDDEN_CHATS_PAGE_SIZE = 20
        SEARCH_PAGE_SIZE = 20
        SEARCH_TOP_MATCHES = 3
        CHAT_TURN_ENQUEUE_RETRY_DELAYS = [ 0.05, 0.2 ].freeze
        CHAT_STREAM_POLL_INTERVAL = 0.25.seconds
        CHAT_STREAM_TIMEOUT = 30.minutes
        CHAT_ATTACHMENT_ALLOWED_MIME_TYPES = %w[
          image/jpeg
          image/png
          image/gif
          image/webp
          application/pdf
        ].freeze
        CHAT_ATTACHMENT_MAX_BASE64_BYTES = 7.megabytes
        PRODUCT_OWNER_EPIC_JOB_MESSAGE = "Product owners cannot add Jobs to Epics directly — " \
          "claim the Epic as a developer to elaborate it.".freeze

        def index
          render json: {
            groups: recent_chats_index_json,
            repositories: Current.user.repositories.active.order(:owner, :name).map { |repository| repository_json(repository) }
          }
        end

        def more
          before_id = Integer(params[:before_id], exception: false)
          if before_id.blank? || before_id <= 0
            render_error("validation_failed", "before_id is required.", status: :unprocessable_content)
            return
          end

          repository_id = chat_index_repository_id
          return if performed?

          scope = chat_index_group_scope(repository_id)
          cursor = scope.find_by(id: before_id)
          unless cursor
            render_error("not_found", "Chat cursor was not found.", status: :not_found)
            return
          end

          chats, has_more = paginated_chat_index_group(scope, before_chat: cursor)
          render json: {
            chats: chats.map { |chat_session| chat_index_json(chat_session) },
            has_more: has_more
          }
        end

        def show
          render json: chat_payload(find_chat_session)
        end

        def update
          chat_session = ChatSession.find(params[:id])
          unless chat_session.user_id == Current.user.id
            render_error("forbidden", "You do not have permission to update this chat.", status: :forbidden)
            return
          end

          chat_params = params[:chat]
          if chat_params.respond_to?(:key?) && chat_params.key?(:chat_provider)
            provider = normalized_chat_provider_param(chat_params[:chat_provider])
            unless provider.nil? || Current.user.chat_provider_configured?(provider)
              render_error("validation_failed", "Chat provider is not configured.", status: :unprocessable_content)
              return
            end

            chat_session.update!(chat_provider: provider)
            render json: chat_payload(chat_session.reload, message: "Chat provider updated.")
            return
          end

          pinned = if chat_params.respond_to?(:key?) && chat_params.key?(:pinned)
            params[:chat][:pinned]
          else
            params[:pinned]
          end
          if pinned.nil?
            render_error("validation_failed", "pinned is required.", status: :unprocessable_content)
            return
          end

          chat_session.update!(pinned: ActiveModel::Type::Boolean.new.cast(pinned))

          render json: chat_payload(chat_session.reload, message: chat_session.pinned? ? "Chat pinned" : "Chat unpinned")
        end

        def share
          chat_session = find_chat_session
          chat_session.with_lock do
            chat_session.update!(share_token: SecureRandom.uuid) if chat_session.share_token.blank?
          end

          render json: { share_url: shared_chat_url(token: chat_session.share_token) }
        end

        def search
          query = search_query
          scope = filtered_chat_search_scope
          return if performed?

          page = search_page

          if query.present?
            render json: search_payload_for_query(scope, query, page)
          else
            render json: search_payload_for_scope(scope, page)
          end
        end

        def search_messages
          query = search_query
          if query.blank?
            render_error("validation_failed", "Query is required.", status: :unprocessable_content)
            return
          end

          chat_session = Current.user.chat_sessions.visible.find(params[:chat_session_id])
          render json: {
            matches: chat_search_rows(query, chat_session_id: chat_session.id).map { |row| chat_search_match_json(row) }
          }
        end

        def hidden
          page = [ Integer(params[:page], exception: false).to_i, 1 ].max
          scope = Current.user.chat_sessions.hidden
          total = scope.count
          chats = scope
            .preload(repository_attachments: :attachable)
            .order(hidden_at: :desc, id: :desc)
            .offset((page - 1) * HIDDEN_CHATS_PAGE_SIZE)
            .limit(HIDDEN_CHATS_PAGE_SIZE)

          render json: {
            chats: chats.map { |chat_session| hidden_chat_json(chat_session) },
            total: total,
            page: page,
            per_page: HIDDEN_CHATS_PAGE_SIZE,
            total_pages: (total.to_f / HIDDEN_CHATS_PAGE_SIZE).ceil
          }
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

        def new
          repository = most_recent_chat_repository
          repository ||= Current.user.repositories.active.order(:owner, :name).first

          render json: {
            default_repository_id: repository&.id
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
          return if performed?

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
          content = message_content(text)
          return if performed?

          user_message = nil
          ApplicationRecord.transaction do
            chat_session.update!(
              last_message_at: Time.current,
              title: chat_session.title.presence
            )
            user_message = chat_session.messages.create!(role: "user", content: content)
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
          request_chat_agent_kill!(chat_session)
          ChatStopReconciler.reconcile!(chat_session: chat_session)
          chat_session.reload.broadcast_controls if chat_session.stop_requested_at?

          render json: chat_payload(chat_session.reload, message: "Stop requested.")
        end

        def switch_provider
          chat_session = find_chat_session
          provider = params[:provider].to_s.strip

          unless User::CHAT_PROVIDERS.include?(provider)
            render_error("validation_failed", "Invalid provider. Must be one of: #{User::CHAT_PROVIDERS.join(", ")}.", status: :unprocessable_content)
            return
          end

          if chat_session.turn_in_flight? || chat_session.agent_busy?
            render_error("turn_in_flight", "Cannot switch provider while a turn is in progress.", status: :unprocessable_content)
            return
          end

          SwitchChatProviderJob.perform_later(chat_session.id, provider)

          render json: { message: "Switching to #{provider}." }
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

        def branch
          source_chat = find_branch_source_chat_session
          return if performed?

          branched_chat = nil
          ApplicationRecord.transaction do
            branched_chat = ChatSession.create!(
              user: source_chat.user,
              repository: source_chat.repository,
              title: "#{source_chat.title.presence || ChatSession.fallback_title_for(source_chat.repository).presence || "New chat"} (branch)",
              chat_provider: source_chat.chat_provider,
              last_message_at: Time.current
            )
            branch_chat_messages!(source_chat, branched_chat)
          end

          render json: { id: branched_chat.id, app_path: chat_path(branched_chat) }, status: :created
        end

        def clear_messages
          chat_session = find_chat_session
          ApplicationRecord.transaction do
            chat_session.messages.destroy_all
            chat_session.chat_queued_messages.destroy_all
            chat_session.update!(last_message_at: nil, stop_requested_at: nil)
          end

          render json: chat_payload(chat_session.reload, message: "Chat history cleared.")
        end

        def mark_read
          find_chat_session.update_columns(last_read_at: Time.current)

          head :no_content
        end

        def mark_unread
          find_chat_session.update_columns(last_read_at: nil)

          head :no_content
        end

        def hide
          chat_session = find_chat_session
          chat_session.update!(hidden_at: Time.current)

          render json: { message: "Chat hidden.", chat: chat_index_json(chat_session.reload) }
        end

        def unhide
          chat_session = find_chat_session
          chat_session.update!(hidden_at: nil)

          render json: { message: "Chat restored.", chat: chat_index_json(chat_session.reload) }
        end

        def enqueue_message
          chat_session = find_chat_session
          text = message_text
          if text.blank?
            render_error("validation_failed", "Message cannot be blank.", status: :unprocessable_content)
            return
          end
          content = message_content(text)
          return if performed?

          queued_message = chat_session.chat_queued_messages.create!(content: content)
          chat_session.touch
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

        def answer_agent_question
          chat_session = find_chat_session
          question = chat_session.agent_questions.find(params[:agent_question_id])
          answer = params[:answer].to_s.strip
          if answer.blank?
            render_error("validation_failed", "Answer cannot be blank.", status: :unprocessable_content)
            return
          end

          if question.answer_and_record!(answer)
            render json: chat_payload(chat_session.reload, message: "Answer submitted.")
          else
            render_error("validation_failed", "Question is no longer active.", status: :unprocessable_content)
          end
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
          message = params[:message_id].present? ? chat_session.messages.find(params[:message_id]) : chat_session.messages.order(:created_at, :id).last
          unless message
            render_error("validation_failed", "Cannot bookmark an empty chat.", status: :unprocessable_content)
            return
          end

          kind = params.dig(:chat_bookmark, :kind).presence_in(ChatBookmark::KINDS) || "manual"
          bookmark = message.bookmarks.create!(label: bookmark_label, kind: kind)

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
          rejection = pending_action.action_type != "schedule_recurring" && !pending_action.queued?
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

          if product_owner_proposal_adds_jobs_to_epics?(proposal)
            render_error("forbidden", PRODUCT_OWNER_EPIC_JOB_MESSAGE, status: :forbidden)
            return
          end

          result = if proposal.epic_bundle?
            ChatEpicProposalMaterializer.new(user: Current.user).file!(proposal)
          else
            ChatProposalFiler.new(user: Current.user, repository: proposal.effective_repository).file!([ proposal ])
          end

          confirmation_message = chat_session.messages.create!(
            role: "system",
            content: proposal_outcome_control_content(
              proposal.reload,
              text: proposal_confirmation_text(proposal, result),
              outcome: :confirmed
            )
          )
          notify_agent_of_proposal_outcome(confirmation_message)
          broadcast_proposal_updated(chat_session, proposal.reload)

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
            proposal.transaction do
              now = Time.current
              proposal.update!(state: "rejected", rejected_at: now)
              proposal.child_proposals.where(state: "proposed").update_all(
                state: "rejected",
                rejected_at: now
              )
            end
            rejection_message = chat_session.messages.create!(
              role: "system",
              content: proposal_outcome_control_content(
                proposal,
                text: proposal_rejection_text(proposal),
                outcome: :rejected
              )
            )
            notify_agent_of_proposal_outcome(rejection_message)
            broadcast_proposal_updated(chat_session, proposal.reload)
            render json: chat_payload(chat_session.reload, message: "Proposal rejected.")
          else
            render_error("validation_failed", "Proposal is no longer proposed.", status: :unprocessable_content)
          end
        end

        def update_proposal
          chat_session = find_chat_session
          proposal = find_proposal(chat_session)

          unless proposal.proposed?
            render_error("validation_failed", "Proposal is no longer proposed.", status: :unprocessable_content)
            return
          end

          attrs = proposal_update_params
          ApplicationRecord.transaction do
            depends_on_job_ids = dependency_ids!(Current.user.jobs, Array(attrs[:depends_on_job_ids]), "depends_on_job_ids")
            depends_on_epic_ids = dependency_ids!(Current.user.epics, Array(attrs[:depends_on_epic_ids]), "depends_on_epic_ids")
            proposal.update!(
              title: attrs[:title],
              body: attrs[:body],
              depends_on_job_ids: depends_on_job_ids,
              depends_on_epic_ids: depends_on_epic_ids
            )
            rebuild_proposal_dependencies!(chat_session, proposal, Array(attrs[:dependency_slugs]))
            proposal.reset_to_proposed_after_edit!
          end

          broadcast_proposal_updated(chat_session, proposal.reload)
          render json: chat_payload(chat_session.reload, message: "Proposal updated.").merge(
            proposal: ::App::ChatMessagePayload.proposal(proposal, chat_session: chat_session, repository: chat_session.repository)
          )
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue ArgumentError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        def search_proposals
          chat_session = find_chat_session
          query = params[:q].to_s.strip
          scope = chat_session.proposals
          scope = scope.where.not(id: params[:exclude_id]) if params[:exclude_id].present?
          if query.present?
            pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
            scope = scope.where("LOWER(title) LIKE :pattern OR LOWER(slug) LIKE :pattern", pattern: pattern)
          end

          render json: {
            proposals: scope.order(:created_at, :id).limit(10).map { |proposal| proposal_search_json(proposal) }
          }
        end

        private

        def search_payload_for_query(scope, query, page)
          allowed_session_ids = scope.distinct.pluck(:id).map(&:to_i)
          grouped_matches = []
          matches_by_chat = {}

          chat_search_rows(query).each do |row|
            chat_session_id = row.fetch(:chat_session_id).to_i
            next unless allowed_session_ids.include?(chat_session_id)

            grouped_matches << chat_session_id unless matches_by_chat.key?(chat_session_id)
            matches_by_chat[chat_session_id] ||= []
            matches_by_chat[chat_session_id] << row
          end

          total = grouped_matches.length
          paged_chat_ids = grouped_matches.slice(search_offset(page), SEARCH_PAGE_SIZE) || []
          sessions_by_id = Current.user.chat_sessions
            .where(id: paged_chat_ids)
            .preload(repository_attachments: :attachable)
            .index_by(&:id)

          {
            results: paged_chat_ids.filter_map do |chat_session_id|
              chat_search_result_json(sessions_by_id[chat_session_id], matches_by_chat.fetch(chat_session_id))
            end,
            total: total,
            page: page,
            per_page: SEARCH_PAGE_SIZE
          }
        end

        def search_payload_for_scope(scope, page)
          total = scope.distinct.count
          sessions = scope
            .distinct
            .preload(repository_attachments: :attachable)
            .order(updated_at: :desc, id: :desc)
            .offset(search_offset(page))
            .limit(SEARCH_PAGE_SIZE)

          {
            results: sessions.map { |chat_session| chat_filter_result_json(chat_session) },
            total: total,
            page: page,
            per_page: SEARCH_PAGE_SIZE
          }
        end

        def filtered_chat_search_scope
          scope = ChatSession.where(user_id: Current.user.id).visible
          scope = apply_chat_attachment_filter(scope, "Repository", :repository_id)
          return scope if performed?

          scope = apply_chat_attachment_filter(scope, "Epic", :epic_id)
          return scope if performed?

          apply_chat_attachment_filter(scope, "Job", :job_id)
        end

        def apply_chat_attachment_filter(scope, attachable_type, param_name)
          attachable_id = optional_positive_integer_param(param_name)
          return scope unless attachable_id

          alias_name = "chat_attachments_#{param_name}_filter"
          quoted_alias = ApplicationRecord.connection.quote_table_name(alias_name)
          quoted_type = ApplicationRecord.connection.quote(attachable_type)

          scope.joins(<<~SQL.squish)
            INNER JOIN chat_attachments #{quoted_alias}
              ON #{quoted_alias}.chat_session_id = chat_sessions.id
              AND #{quoted_alias}.attachable_type = #{quoted_type}
              AND #{quoted_alias}.attachable_id = #{attachable_id}
          SQL
        end

        def optional_positive_integer_param(name)
          raw = params[name]
          return if raw.blank?

          value = Integer(raw, exception: false)
          return value if value&.positive?

          render_error("bad_request", "#{name} must be a positive integer.", status: :bad_request)
          nil
        end

        def search_query
          params[:q].to_s.strip
        end

        def proposal_update_params
          params.require(:proposal).permit(:title, :body, dependency_slugs: [], depends_on_job_ids: [], depends_on_epic_ids: [])
        end

        def rebuild_proposal_dependencies!(chat_session, proposal, dependency_slugs)
          slugs = dependency_slugs.map(&:to_s).map(&:strip).reject(&:blank?).uniq
          dependencies = chat_session.proposals.where(slug: slugs).index_by(&:slug)
          missing = slugs - dependencies.keys
          raise ArgumentError, "Unknown proposal dependency: #{missing.first}" if missing.any?

          proposal.dependency_edges.destroy_all
          slugs.each do |slug|
            proposal.dependency_edges.create!(depends_on: dependencies.fetch(slug))
          end
        end

        def dependency_ids!(scope, raw_ids, name)
          ids = raw_ids.map(&:to_i).select(&:positive?).uniq
          found_ids = scope.where(id: ids).pluck(:id)
          missing = ids - found_ids
          raise ArgumentError, "Unknown #{name}: #{missing.first}" if missing.any?

          ids
        end

        def proposal_search_json(proposal)
          {
            id: proposal.id,
            slug: proposal.slug,
            title: proposal.title,
            state: proposal.state
          }
        end

        def broadcast_proposal_updated(chat_session, proposal)
          AppEvents.broadcast(
            user: chat_session.user,
            type: "updated",
            resource: "chat",
            id: chat_session.id,
            changed: [ "proposal" ],
            payload: {
              action: "update_proposal",
              proposal_id: proposal.id
            }
          )
        end

        def search_page
          [ Integer(params[:page], exception: false).to_i, 1 ].max
        end

        def search_offset(page)
          (page - 1) * SEARCH_PAGE_SIZE
        end

        def chat_search_rows(query, chat_session_id: nil)
          ChatMessageSearchIndex.search(
            query,
            user_id: Current.user.id,
            chat_session_id: chat_session_id,
            limit: nil,
            snippet_start: "<b>",
            snippet_end: "</b>",
            snippet_tokens: 50
          )
        end

        def chat_search_result_json(chat_session, rows)
          return unless chat_session

          top_matches = rows.first(SEARCH_TOP_MATCHES).map { |row| chat_search_match_json(row) }
          {
            chat_session_id: chat_session.id,
            chat_title: chat_search_title(chat_session),
            best_snippet: top_matches.first&.fetch(:snippet),
            best_match_message_id: top_matches.first&.fetch(:message_id),
            top_matches: top_matches,
            total_match_count: rows.length,
            has_more_matches: rows.length > SEARCH_TOP_MATCHES
          }
        end

        def chat_filter_result_json(chat_session)
          {
            chat_session_id: chat_session.id,
            chat_title: chat_search_title(chat_session),
            best_snippet: nil,
            best_match_message_id: nil,
            top_matches: [],
            total_match_count: 0,
            has_more_matches: false
          }
        end

        def chat_search_match_json(row)
          {
            message_id: row.fetch(:chat_message_id).to_i,
            role: row.fetch(:role),
            snippet: row.fetch(:snippet),
            created_at: row.fetch(:created_at)
          }
        end

        def chat_search_title(chat_session)
          chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository)
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
            chat_available: Current.user.chat_available?,
            turn_in_flight: chat_session.turn_in_flight?,
            agent_busy: chat_session.agent_busy?,
            switching_provider: false,
            has_more_older: has_more_older,
            messages: messages_json(messages, repository: repository),
            bookmarks: chat_session.bookmarks.includes(:chat_message).map { |bookmark| bookmark_json(bookmark) },
            recent_chats: recent_chats_json(chat_session),
            pending_actions: pending_actions_json(chat_session),
            agent_questions: chat_session.agent_questions_payload,
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
              credentials_path: "/credentials",
              repositories_path: repositories_path,
              app_messages_path: "/api/v1/app/chats/#{chat_session.id}/messages",
              app_message_path: "/api/v1/app/chats/#{chat_session.id}/message",
              app_rename_path: "/api/v1/app/chats/#{chat_session.id}/rename",
              app_clear_path: "/api/v1/app/chats/#{chat_session.id}/messages",
              app_branch_path: "/api/v1/app/chats/#{chat_session.id}/branch",
              app_share_path: "/api/v1/app/chats/#{chat_session.id}/share",
              app_enqueue_message_path: "/api/v1/app/chats/#{chat_session.id}/queued_messages",
              app_stop_path: "/api/v1/app/chats/#{chat_session.id}/stop",
              app_bookmarks_path: "/api/v1/app/chats/#{chat_session.id}/bookmarks",
              app_attachments_path: "/api/v1/app/chats/#{chat_session.id}/attachments",
              app_whiteboard_path: "/api/v1/app/chats/#{chat_session.id}/whiteboard",
              app_switch_provider_path: "/api/v1/app/chats/#{chat_session.id}/switch_provider"
            }
          }
        end

        def paginated_tail(chat_session)
          scope = message_scope(chat_session)
          fetched = scope.order(id: :desc).limit(PAGE_SIZE + 1).to_a
          has_more = fetched.size > PAGE_SIZE
          [ fetched.first(PAGE_SIZE).reverse, has_more ]
        end

        def paginated_before(chat_session, before_id)
          scope = message_scope(chat_session)
          scope = scope.where("id < ?", before_id) if before_id&.positive?
          fetched = scope.order(id: :desc).limit(PAGE_SIZE + 1).to_a
          has_more = fetched.size > PAGE_SIZE
          [ fetched.first(PAGE_SIZE).reverse, has_more ]
        end

        def message_scope(chat_session)
          scope = ChatMessage.where(chat_session_id: chat_session.id)
          scope = force_chat_message_cursor_index(scope) if mysql_adapter?

          scope.includes(:pending_action, proposal: [ :repository, :job, :epic, :target_epic, dependencies: [], child_proposals: [ :repository, :job, dependencies: [] ] ])
        end

        def force_chat_message_cursor_index(scope)
          scope.from(Arel.sql("#{ChatMessage.quoted_table_name} FORCE INDEX (index_chat_messages_on_session_id_and_id)"))
        end

        def mysql_adapter?
          ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
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
            .visible
            .order(Arel.sql("chat_sessions.pinned DESC, #{chat_activity_order_sql} DESC"), id: :desc)
            .limit(20)
            .pluck(:id)

          chat_ids = chat_ids.first(19) + [ current_chat_session.id ] if current_chat_session.hidden_at.blank? && !chat_ids.include?(current_chat_session.id)

          Current.user.chat_sessions
            .visible
            .where(id: chat_ids)
            .preload(repository_attachments: :attachable)
            .to_a
            .sort_by { |chat_session| [ chat_activity_at(chat_session), chat_session.id ] }
            .reverse
            .map do |chat_session|
            chat_json(chat_session).merge(
              current: chat_session.id == current_chat_session.id,
              last_message_at: chat_session.last_message_at&.iso8601,
              unread: chat_unread?(chat_session),
              created_at: chat_session.created_at.iso8601,
              updated_at: chat_session.updated_at.iso8601
            )
          end
        end

        def recent_chats_index_json
          groups = []
          general_chats, general_has_more = paginated_chat_index_group(chat_index_group_scope(nil))
          if general_chats.any?
            groups << chat_index_group_json(
              key: "general",
              label: "General",
              repository_id: nil,
              chats: general_chats,
              has_more: general_has_more
            )
          end

          chat_index_repositories.each do |repository|
            chats, has_more = paginated_chat_index_group(chat_index_group_scope(repository.id))
            next if chats.blank?

            groups << chat_index_group_json(
              key: "repository-#{repository.id}",
              label: repository.slug,
              repository_id: repository.id,
              chats: chats,
              has_more: has_more
            )
          end

          groups.sort_by { |group| group.delete(:active_at) || Time.at(0) }.reverse
        end

        def chat_index_group_json(key:, label:, repository_id:, chats:, has_more:)
          {
            key: key,
            label: label,
            repository_id: repository_id,
            chats: chats.map { |chat_session| chat_index_json(chat_session) },
            has_more: has_more,
            active_at: chats.map { |chat_session| chat_activity_timestamp(chat_session) }.max
          }
        end

        def chat_index_json(chat_session)
          chat_json(chat_session).merge(
            last_message_at: chat_session.last_message_at&.iso8601,
            unread: chat_unread?(chat_session),
            created_at: chat_session.created_at.iso8601,
            updated_at: chat_session.updated_at.iso8601
          )
        end

        def paginated_chat_index_group(scope, before_chat: nil)
          scope = chat_index_before(scope, before_chat) if before_chat
          fetched = scope.preload(repository_attachments: :attachable).limit(CHAT_INDEX_GROUP_SIZE + 1).to_a
          [ fetched.first(CHAT_INDEX_GROUP_SIZE), fetched.size > CHAT_INDEX_GROUP_SIZE ]
        end

        def chat_index_before(scope, before_chat)
          timestamp = chat_activity_timestamp(before_chat)
          scope.where(
            "chat_sessions.pinned < ? OR (chat_sessions.pinned = ? AND ((#{chat_activity_order_sql}) < ? OR ((#{chat_activity_order_sql}) = ? AND chat_sessions.id < ?)))",
            before_chat.pinned? ? 1 : 0,
            before_chat.pinned? ? 1 : 0,
            timestamp,
            timestamp,
            before_chat.id
          )
        end

        def chat_index_group_scope(repository_id)
          scope = Current.user.chat_sessions
            .visible
            .left_outer_joins(:repository_attachments)
            .order(Arel.sql("chat_sessions.pinned DESC, #{chat_activity_order_sql} DESC, chat_sessions.id DESC"))

          if repository_id.present?
            scope.where(chat_attachments: { attachable_type: "Repository", attachable_id: repository_id })
          else
            scope.where(chat_attachments: { id: nil })
          end
        end

        def chat_index_repositories
          repository_ids = Current.user.chat_sessions
            .visible
            .joins(:repository_attachments)
            .where(chat_attachments: { attachable_type: "Repository" })
            .distinct
            .pluck("chat_attachments.attachable_id")

          Current.user.repositories.where(id: repository_ids).order(:owner, :name)
        end

        def chat_index_repository_id
          repository_id = params[:repository_id].to_s
          return nil if repository_id == "general"

          parsed = Integer(repository_id, exception: false)
          return parsed if parsed

          render_error("validation_failed", "repository_id is required.", status: :unprocessable_content)
          nil
        end

        def chat_activity_timestamp(chat_session)
          chat_activity_at(chat_session)
        end

        def chat_activity_order_sql
          "COALESCE(chat_sessions.last_message_at, chat_sessions.created_at)"
        end

        def chat_activity_at(chat_session)
          chat_session.last_message_at || chat_session.created_at
        end

        def hidden_chat_json(chat_session)
          chat_index_json(chat_session).merge(
            hidden_at: chat_session.hidden_at&.iso8601,
            app_unhide_path: "/api/v1/app/chats/#{chat_session.id}/unhide"
          )
        end

        def chat_unread?(chat_session)
          chat_session.last_message_at.present? &&
            (chat_session.last_read_at.blank? || chat_session.last_message_at > chat_session.last_read_at)
        end

        def pending_actions_json(chat_session)
          chat_session.pending_actions.where(state: %w[queued pending]).order(:created_at, :id).map do |action|
            {
              id: action.id,
              label: pending_action_label(action),
              detail: pending_action_detail(action),
              state: action.state,
              action: action.action,
              action_type: action.action_type,
              chat_message_id: action.message&.id,
              app_confirm_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}/confirm",
              app_reject_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}/reject",
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
          content = message_content(text) if text.present?
          return if performed?

          chat_session = nil
          user_message = nil

          ApplicationRecord.transaction do
            chat_session = ChatSession.create!(
              user: Current.user,
              repository: repository,
              title: nil,
              last_message_at: text.present? ? Time.current : nil
            )
            if text.present?
              user_message = chat_session.messages.create!(role: "user", content: content)
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

        def notify_agent_of_proposal_outcome(message)
          chat_session = message.chat_session
          return unless chat_session

          ApplicationRecord.transaction do
            chat_session.update!(
              last_message_at: Time.current,
              title: chat_session.title.presence
            )
          end

          enqueue_chat_turn(chat_session, message)
        end

        def proposal_outcome_control_content(proposal, text:, outcome:)
          {
            "text" => text,
            "source" => ChatProposalOutcomeNotification::SOURCE,
            "outcome" => outcome.to_s,
            "acknowledgment" => ChatProposalOutcomeNotification.acknowledgment(proposal, outcome: outcome)
          }
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

        def find_branch_source_chat_session
          chat_session = ChatSession.find(params[:id])
          return chat_session if chat_session.user_id == Current.user.id

          render_error("forbidden", "You cannot branch this chat.", status: :forbidden)
          nil
        end

        def branch_chat_messages!(source_chat, branched_chat)
          rows = source_chat.messages.order(:created_at, :id).map do |message|
            message.attributes.slice(
              "role",
              "content",
              "tool_name",
              "tool_use_id",
              "created_at",
              "updated_at"
            ).merge(
              "chat_session_id" => branched_chat.id,
              "proposal_id" => nil,
              "pending_action_id" => nil
            )
          end
          ChatMessage.insert_all!(rows) if rows.any?
        end

        def find_pending_action(chat_session)
          chat_session.pending_actions.find(params[:pending_action_id])
        end

        def find_proposal(chat_session)
          chat_session.proposals.find(params[:proposal_id])
        end

        def product_owner_proposal_adds_jobs_to_epics?(proposal)
          return false unless Current.user.product_owner?

          if proposal.epic_bundle?
            return proposal.child_proposals.where(state: "proposed").exists?
          end

          ChatProposalFiler.ordered_closure([ proposal ]).any? do |candidate|
            candidate.proposed? &&
              candidate.target_epic_id.present? &&
              (candidate.syrus_issue? || candidate.job?)
          end
        end

        def message_text
          (params[:content].presence || params.dig(:chat_message, :text)).to_s.strip
        end

        def message_content(text)
          content = { "text" => text }
          attachments = params.dig(:chat_message, :attachments)
          return content if attachments.blank?

          sanitized = sanitized_attachments(attachments)
          return if performed?

          content["attachments"] = sanitized
          content
        end

        def sanitized_attachments(attachments)
          unless attachments.is_a?(Array)
            render_error("validation_failed", "Attachments must be an array.", status: :unprocessable_content)
            return
          end

          attachments.map do |attachment|
            attributes = attachment.respond_to?(:to_unsafe_h) ? attachment.to_unsafe_h : attachment
            unless attributes.respond_to?(:[])
              render_error("validation_failed", "Attachments must be objects.", status: :unprocessable_content)
              return
            end

            name = attributes["name"] || attributes[:name]
            mime_type = (attributes["mime_type"] || attributes[:mime_type]).to_s
            data = (attributes["data"] || attributes[:data]).to_s

            unless CHAT_ATTACHMENT_ALLOWED_MIME_TYPES.include?(mime_type)
              render_error("validation_failed", "Attachment MIME type is not allowed.", status: :unprocessable_content)
              return
            end

            if data.bytesize > CHAT_ATTACHMENT_MAX_BASE64_BYTES
              render_error("validation_failed", "Attachment data must be 7 MB or smaller.", status: :unprocessable_content)
              return
            end

            { "name" => name.to_s, "mime_type" => mime_type, "data" => data }
          end
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
              .includes(:pending_action, proposal: [ :repository, :job, :epic, :target_epic, dependencies: [], child_proposals: [ :repository, dependencies: [] ] ])
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

        def most_recent_chat_repository
          recent_repo_id = Current.user.chat_sessions
            .joins(:repository_attachments)
            .order("chat_sessions.created_at DESC")
            .limit(1)
            .pick("chat_attachments.attachable_id")

          Current.user.repositories.active.find_by(id: recent_repo_id) if recent_repo_id
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
          return repository_from_slug if type == "Repository" && params[:repository_slug].present?

          attachment_search_results(chat_session).first
        end

        def repository_from_slug
          owner, name = params[:repository_slug].to_s.strip.split("/", 2)
          return if owner.blank? || name.blank?

          Current.user.repositories.active.find_by(owner: owner, name: name)
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
            title: chat_session.title.presence || ChatSession.fallback_title_for(repository),
            title_pending: chat_session.title_pending?,
            pinned: chat_session.pinned?,
            pinned_context: chat_session.pinned_context,
            chat_provider: chat_session.chat_provider,
            effective_chat_provider: chat_session.effective_chat_provider,
            effective_chat_provider_label: chat_provider_label(chat_session.effective_chat_provider),
            chat_provider_options: chat_provider_options(chat_session),
            chat_path: chat_path(chat_session),
            repository: repository ? repository_json(repository).merge(repository_path: repository_path(repository)) : nil,
            turn_in_flight: chat_session.turn_in_flight?,
            agent_busy: chat_session.agent_busy?,
            stop_requested_at: chat_session.stop_requested_at&.iso8601,
            cumulative_input_tokens: chat_session.cumulative_input_tokens.to_i,
            cumulative_output_tokens: chat_session.cumulative_output_tokens.to_i,
            cumulative_cost_usd: chat_session.cumulative_cost.to_f,
            pending_proposal_count: chat_session.proposals.where(state: "proposed").count +
              chat_session.pending_actions.where(state: "pending").count
          }
        end

        def request_chat_agent_kill!(chat_session)
          SpawnedProcess.running
                        .where(kind: "agent", workdir: chat_session.workspace_root.to_s)
                        .find_each { |process| process.request_kill!(user: Current.user) }
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug
          }
        end

        def normalized_chat_provider_param(value)
          value.to_s.strip.presence
        end

        def chat_provider_label(provider)
          case provider
          when "claude" then "Claude"
          when "codex" then "Codex"
          else provider.to_s.titleize
          end
        end

        def chat_provider_options(chat_session)
          configured = Current.user.configured_agent_providers
          [
            {
              value: nil,
              label: "Default",
              configured: Current.user.chat_provider_configured?(chat_session.user.effective_chat_provider),
              effective_provider: chat_session.user.effective_chat_provider,
              effective_label: chat_provider_label(chat_session.user.effective_chat_provider)
            }
          ] + User::CHAT_PROVIDERS.map do |provider|
            {
              value: provider,
              label: chat_provider_label(provider),
              configured: configured.include?(provider),
              effective_provider: provider,
              effective_label: chat_provider_label(provider)
            }
          end
        end

        def attachment_label(record)
          case record
          when Repository then record.slug
          when Epic then [ record.slug, record.title.presence ].compact.join(": ")
          when Job then "#{record.slug}: #{record.issue_title.presence || record.issue_number || record.kind}"
          when Document then "#{record.title} (#{record.repository&.slug})"
          else record.try(:name).presence || record.try(:title).presence || "#{record.class.name} ##{record.id}"
          end
        end

        def pending_action_label(action)
          payload = action.payload || {}
          case action.action
          when "cancel_job"
            "Cancel #{::App::Presentation.job_slug(payload['job_id'])}"
          when "retry_job"
            "Retry #{::App::Presentation.job_slug(payload['job_id'])}"
          when "rebase_job"
            "Rebase #{::App::Presentation.job_slug(payload['job_id'])}"
          when "reopen_job"
            "Reopen #{::App::Presentation.job_slug(payload['job_id'])}"
          when "fire_scheduled_task_now"
            "Fire scheduled task ##{payload['scheduled_task_id']}"
          when "create_repo_document"
            "Create document #{payload['title'].to_s.inspect}"
          when "delete_repo_document"
            "Delete document #{payload['title'].to_s.presence || "##{payload['document_id']}"}"
          when "poll_job_feedback"
            "Poll PR feedback for #{::App::Presentation.job_slug(payload['job_id'])}"
          when "check_job_mergeability"
            "Check mergeability for #{::App::Presentation.job_slug(payload['job_id'])}"
          when "delegate_issue"
            "Delegate issue ##{payload['issue_number']}"
          when "pause_landing_queue"
            "Pause landing queue"
          when "resume_landing_queue"
            "Resume landing queue"
          when "submit_chat_feedback"
            "Submit feedback on #{::App::Presentation.job_slug(payload['job_id'])}"
          when "reopen_epic_and_attach_job"
            "Reopen Epic ##{payload['epic_id']} and attach #{::App::Presentation.job_slug(payload['job_id'])}"
          when "admin_kill_process"
            "Kill process ##{payload['process_id']}"
          when "admin_reap_stale_runs"
            "Force-reap stale runs"
          when "admin_pause_polling"
            "Pause repository polling"
          when "admin_unpause_polling"
            "Resume repository polling"
          when "admin_pause_runs"
            "Pause runs"
          when "admin_unpause_runs"
            "Resume runs"
          when "admin_clear_github_cache"
            "Clear GitHub API cache"
          when "admin_pause_user_scheduling"
            "Pause scheduling for user ##{payload['user_id']}"
          when "admin_unpause_user_scheduling"
            "Resume scheduling for user ##{payload['user_id']}"
          when "admin_retry_step"
            "Retry step #{payload['step_slug']} on workflow ##{payload['workflow_id']}"
          when "admin_cleanup_workspace"
            "Delete workspace for workflow ##{payload['workflow_id']}"
          when "admin_refresh_installations"
            "Refresh GitHub App installations"
          else
            payload["label"].presence || action.action_type.to_s.humanize
          end
        end

        def pending_action_detail(action)
          payload = action.payload || {}
          case action.action.presence || action.action_type
          when "submit_chat_feedback"
            payload["feedback"].presence
          when "schedule_recurring"
            [
              [ payload["label"], payload["cron_expression"] ].compact_blank.join(" — ").presence,
              payload["prompt"].presence
            ].compact.join("\n\n").presence
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
            "Proposal confirmed and filed as #{record.slug}."
          when Epic
            "Proposal confirmed and filed as #{record.slug}."
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
          %(#{job.slug} "#{job.issue_title}")
        end
      end
    end
  end
end
