module Api
  module V1
    module App
      class ChatsController < BaseController
        include ChatAttachmentSearch
        include ChatAttachableResolution
        include ChatIndexPayload
        include ChatMessagePagination
        include ChatPendingActions
        include ChatProposalMutation
        include ChatProposalOutcome
        include ChatProviderOptions
        include ChatSearch
        include ChatTurnStreaming
        include ChatSerialization
        include ChatMessageParams
        include ChatSessionLifecycle
        include ChatLockErrors
        include ChatProposalOutcomeNotice

        HIDDEN_CHATS_PAGE_SIZE = 20
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

          if chat_params.respond_to?(:key?) && chat_params.key?(:chat_model)
            model = chat_params[:chat_model].to_s.strip.presence
            if model
              valid_models = available_chat_models_for(chat_session).map { |m| m[:value] }
              unless valid_models.include?(model)
                render_error("validation_failed", "Invalid chat model.", status: :unprocessable_content)
                return
              end
            end

            chat_session.update!(chat_model: model)
            render json: chat_payload(chat_session.reload, message: "Chat model updated.")
            return
          end

          if chat_params.respond_to?(:key?) && chat_params.key?(:mode)
            mode = chat_params[:mode].to_s.strip.presence
            if mode && !ChatSession::MODES.include?(mode)
              render_error("validation_failed", "Invalid mode. Must be one of: #{ChatSession::MODES.join(", ")}.", status: :unprocessable_content)
              return
            end
            if mode == "coding" && !Feature.coding_mode_enabled?
              render_error("feature_disabled", "Coding Mode is not enabled on this instance.", status: :unprocessable_content)
              return
            end
            if mode == "local" && !Feature.local_mode_enabled?
              render_error("validation_failed", "Local mode is not enabled.", status: :unprocessable_content)
              return
            end

            chat_session.update!(mode: mode)
            render json: chat_payload(chat_session.reload, message: "Chat mode updated.")
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
          if text.blank? && !message_has_attachments?
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

        def daemon_connection
          chat_session = find_chat_session

          unless Feature.local_mode_enabled?
            render_error("forbidden", "Local mode is not enabled.", status: :forbidden)
            return
          end

          unless chat_session.mode == "local"
            render_error("validation_failed", "Chat is not in local mode.", status: :unprocessable_content)
            return
          end

          state = params[:state].to_s.strip
          unless ChatSession::DAEMON_STATES.include?(state)
            render_error("validation_failed", "Invalid state. Must be one of: #{ChatSession::DAEMON_STATES.join(", ")}.", status: :unprocessable_content)
            return
          end

          attrs = { local_daemon_state: state }
          if state == "connected"
            attrs[:local_daemon_repo] = params[:repo].to_s.strip.presence
            attrs[:local_daemon_branch] = params[:branch].to_s.strip.presence
          else
            attrs[:local_daemon_repo] = nil
            attrs[:local_daemon_branch] = nil
          end

          chat_session.update!(attrs)

          render json: { message: "Daemon connection state updated." }
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
              title: branch_chat_title(source_chat),
              chat_provider: source_chat.chat_provider,
              last_message_at: Time.current
            )
            branch_chat_messages!(source_chat, branched_chat)
          end

          render json: { id: branched_chat.id, app_path: chat_path(branched_chat) }, status: :created
        end

        # Hard-deletes a chat: the ChatSession row and every dependent
        # row (messages, bookmarks, queued messages, attachments,
        # proposals, pending actions, agent questions, wakeups,
        # whiteboard + snapshots, captured agent session) go in the
        # request transaction; the search-index rows, workspace
        # directory, and per-chat agent homes are cleaned up post-commit
        # by ChatSessionCleanupJob on the worker (the web pod doesn't
        # mount the workspace PVC). Refused while a turn is actively
        # running.
        def destroy
          chat_session = find_chat_session
          if chat_session.turn_in_flight? || chat_session.agent_busy?
            render_error(
              "turn_in_flight",
              "Cannot delete this chat while a turn is in progress. Stop the turn first.",
              status: :conflict
            )
            return
          end

          chat_session.destroy!

          render json: { message: "Chat deleted." }
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
          if text.blank? && !message_has_attachments?
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
          existing = queued_message.content.is_a?(Hash) ? queued_message.content : {}
          if text.blank? && !queued_message.carries_media?
            render_error("validation_failed", "Message cannot be blank.", status: :unprocessable_content)
            return
          end

          # Edit only the note text; PRESERVE the media (video_walkthrough_id /
          # source / attachments) so editing a media-carrying queued message —
          # e.g. adding a note to a pending walkthrough turn — doesn't discard it
          # and silently drop the handoff on promotion.
          queued_message.update!(content: existing.merge("text" => text))
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

        def create_scratchpad_item
          chat_session = find_chat_session
          content = params.dig(:scratchpad_item, :content).to_s.strip
          if content.blank?
            render_error("validation_failed", "Content cannot be blank.", status: :unprocessable_content)
            return
          end

          max_position = chat_session.scratchpad_items.maximum(:position) || -1
          chat_session.scratchpad_items.create!(content: content, position: max_position + 1)

          render json: chat_payload(chat_session.reload, message: "Scratch pad item added.")
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def update_scratchpad_item
          chat_session = find_chat_session
          item = chat_session.scratchpad_items.find(params[:item_id])
          content = params.dig(:scratchpad_item, :content).to_s.strip
          if content.blank?
            render_error("validation_failed", "Content cannot be blank.", status: :unprocessable_content)
            return
          end

          item.update!(content: content)
          render json: chat_payload(chat_session.reload, message: "Scratch pad item updated.")
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def destroy_scratchpad_item
          chat_session = find_chat_session
          item = chat_session.scratchpad_items.find(params[:item_id])
          item.destroy!

          render json: chat_payload(chat_session.reload, message: "Scratch pad item deleted.")
        end

        def reorder_scratchpad_items
          chat_session = find_chat_session
          ids = Array(params[:ids]).map { |id| Integer(id, exception: false) }.compact
          if ids.blank?
            render_error("validation_failed", "ids is required.", status: :unprocessable_content)
            return
          end

          items = chat_session.scratchpad_items.where(id: ids).index_by(&:id)
          if items.size != ids.size
            render_error("not_found", "One or more scratchpad items were not found.", status: :not_found)
            return
          end

          ids.each_with_index do |id, position|
            items[id].update_columns(position: position)
          end

          chat_session.broadcast_controls
          render json: chat_payload(chat_session.reload, message: "Scratch pad items reordered.")
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
          epic_started = maybe_start_confirmed_epic!(proposal, result)

          confirmation_message = chat_session.messages.create!(
            role: "system",
            content: proposal_outcome_control_content(
              proposal.reload,
              text: proposal_confirmation_text(proposal, result, epic_started: epic_started),
              outcome: :confirmed
            )
          )
          notify_agent_of_proposal_outcome(confirmation_message)
          broadcast_proposal_updated(chat_session, proposal.reload)

          render json: chat_payload(chat_session.reload, message: proposal_confirmed_notice(proposal, result, epic_started: epic_started))
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

        def cancel_coding_checkout
          chat_session = find_chat_session
          unless Feature.coding_mode_enabled?
            render_error("feature_disabled", "Coding Mode is not enabled on this instance.", status: :not_found)
            return
          end

          repository = chat_session.repository
          unless repository
            render_error("not_found", "No repository attached to this chat.", status: :not_found)
            return
          end

          if chat_session.coding_checkout_branch.blank?
            render_error("not_found", "No active coding checkout for this chat.", status: :not_found)
            return
          end

          ChatWorkspace.cancel_coding_checkout!(chat_session, repository)
          render json: chat_payload(chat_session.reload, message: "Coding checkout cancelled.")
        rescue ActiveRecord::RecordNotFound
          raise
        rescue StandardError => e
          render_error("server_error", "Could not cancel coding checkout: #{e.message}", status: :internal_server_error)
        end

        def coding_files
          chat_session = find_chat_session
          unless Feature.coding_mode_enabled?
            render_error("feature_disabled", "Coding Mode is not enabled on this instance.", status: :not_found)
            return
          end

          unless chat_session.repository
            render_error("not_found", "No repository attached to this chat.", status: :not_found)
            return
          end

          if chat_session.coding_checkout_branch.blank?
            render_error("not_found", "No active coding checkout for this chat.", status: :not_found)
            return
          end

          result = ChatWorkspace.file_tree(chat_session, chat_session.repository)
          unless result
            render_error("not_found", "Coding checkout directory not found.", status: :not_found)
            return
          end

          render json: result
        end

        def coding_file
          chat_session = find_chat_session
          unless Feature.coding_mode_enabled?
            render_error("feature_disabled", "Coding Mode is not enabled on this instance.", status: :not_found)
            return
          end

          unless chat_session.repository
            render_error("not_found", "No repository attached to this chat.", status: :not_found)
            return
          end

          if chat_session.coding_checkout_branch.blank?
            render_error("not_found", "No active coding checkout for this chat.", status: :not_found)
            return
          end

          file_path = params[:path].to_s.strip
          if file_path.blank?
            render_error("validation_failed", "path parameter is required.", status: :unprocessable_content)
            return
          end

          result = ChatWorkspace.file_content(chat_session, chat_session.repository, file_path)
          if result.nil?
            render_error("not_found", "File not found in coding checkout.", status: :not_found)
            return
          end

          render json: result.merge(path: file_path)
        end

        def coding_diff
          chat_session = find_chat_session
          unless Feature.coding_mode_enabled?
            render_error("feature_disabled", "Coding Mode is not enabled on this instance.", status: :not_found)
            return
          end

          unless chat_session.repository
            render json: { diff: "", mode: "cumulative", checkout_branch: nil }
            return
          end

          mode = params[:mode].to_s == "turn" ? :turn : :cumulative
          diff = ChatWorkspace.coding_diff(chat_session, chat_session.repository, mode: mode)

          render json: {
            diff: diff,
            mode: mode.to_s,
            checkout_branch: chat_session.coding_checkout_branch
          }
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

        # Walkthrough videos shared in this chat, for the workspace media panel.
        # Metadata only — the video itself is far too large to inline (unlike the
        # base64 image attachments) and is pruned after a retention window, so
        # `has_video` tells the UI whether it can still be played back / re-analyzed.
        ATTACHMENT_LABEL_FORMATTERS = {
          Repository => ->(r) { r.slug },
          Epic       => ->(r) { [ r.slug, r.title.presence ].compact.join(": ") },
          Job        => ->(r) { "#{r.slug}: #{r.issue_title.presence || r.issue_number || r.kind}" },
          Document   => ->(r) { "#{r.title} (#{r.repository&.slug})" }
        }.freeze

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

        CLAUDE_CHAT_MODELS = [
          { value: "claude-opus-4-7", label: "Claude Opus 4.7" },
          { value: "claude-sonnet-4-6", label: "Claude Sonnet 4.6" },
          { value: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5" }
        ].freeze

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
            chat_model: chat_session.chat_model,
            available_chat_models: available_chat_models_for(chat_session),
            mode: chat_session.mode,
            local_daemon_state: chat_session.local_daemon_state,
            local_daemon_repo: chat_session.local_daemon_repo,
            local_daemon_branch: chat_session.local_daemon_branch,
            chat_path: chat_path(chat_session),
            repository: repository ? repository_json(repository).merge(repository_path: repository_path(repository)) : nil,
            turn_in_flight: chat_session.turn_in_flight?,
            agent_busy: chat_session.agent_busy?,
            stop_requested_at: chat_session.stop_requested_at&.iso8601,
            suggested_next_step: chat_session.suggested_next_step,
            cumulative_input_tokens: chat_session.cumulative_input_tokens.to_i,
            cumulative_output_tokens: chat_session.cumulative_output_tokens.to_i,
            cumulative_cost_usd: chat_session.cumulative_cost.to_f,
            pending_proposal_count: chat_session.proposals.where(state: "proposed").count +
              chat_session.pending_actions.where(state: "pending").count,
            confirmed_proposal_count: chat_session.proposals.confirmed.count,
            linked_direct_job_count: Job.where(linked_chat_id: chat_session.id, kind: "direct").count,
            scratchpad_items_count: chat_session.scratchpad_items.count,
            coding_checkout_uncommitted: chat_session.coding_checkout_uncommitted?,
            coding_checkout_branch: chat_session.coding_checkout_branch
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

        def attachment_label(record)
          formatter = ATTACHMENT_LABEL_FORMATTERS[record.class]
          formatter ? formatter.call(record) : record.try(:name).presence || record.try(:title).presence || "#{record.class.name} ##{record.id}"
        end

        def available_chat_models_for(chat_session)
          return [] unless chat_session.effective_chat_provider == "claude"

          CLAUDE_CHAT_MODELS
        end

      end
    end
  end
end
