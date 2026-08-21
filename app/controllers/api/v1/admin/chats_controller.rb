module Api
  module V1
    module Admin
      # Token-auth chat transcript diagnostics.
      #
      #   GET /api/v1/admin/chats
      #   GET /api/v1/admin/chats/:id
      #
      # This deliberately returns raw ChatMessage content instead of
      # the SPA-rendered message shape. Admin API clients use this for
      # transcript review and agent-quality debugging.
      class ChatsController < BaseController
        DEFAULT_PER = 50
        MAX_PER = 200

        def index
          scope = ChatSession.preload(:user, chat_attachments: :attachable)
                             .left_joins(:messages)
                             .group("chat_sessions.id")
                             .select("chat_sessions.*, COUNT(chat_messages.id) AS messages_count")
                             .order(Arel.sql("COALESCE(chat_sessions.last_message_at, chat_sessions.updated_at, chat_sessions.created_at) DESC"))
          scope = scope.joins(:user).where("users.email_address LIKE ?", "%#{params[:user]}%") if params[:user].present?
          scope = filter_by_repository(scope) if params[:repo].present?
          scope = scope.where("chat_sessions.created_at >= ?", parse_since) if params[:since].present?

          per = per_param
          page = page_param
          total = scope.unscope(:select, :order).count.size
          chats = scope.offset((page - 1) * per).limit(per).to_a

          render json: {
            count: chats.size,
            total: total,
            page: page,
            per: per,
            chats: chats.map { |chat| serialize_compact(chat) }
          }
        end

        def show
          chat = ChatSession.includes(
            :user,
            chat_attachments: :attachable
          ).find(params[:id])

          per = per_param
          messages, has_more_older = paginated_messages(chat, before_id: before_id, per: per)

          render json: serialize_chat(chat).merge(
            messages_page: {
              before: before_id,
              count: messages.size,
              per: per,
              has_more_older: has_more_older
            },
            messages: messages.map { |message| serialize_message(message) }
          )
        end

        private

        def filter_by_repository(scope)
          owner, name = params[:repo].to_s.split("/", 2)
          return scope.none if owner.blank? || name.blank?

          repository_ids = Repository.where(owner: owner, name: name).select(:id)
          scope.joins(:chat_attachments)
               .where(chat_attachments: { attachable_type: "Repository", attachable_id: repository_ids })
        end

        def per_param
          (params[:per].presence || DEFAULT_PER).to_i.clamp(1, MAX_PER)
        end

        def page_param
          [ params[:page].to_i, 1 ].max
        end

        def before_id
          Integer(params[:before], exception: false)
        end

        def parse_since
          Time.iso8601(params[:since])
        rescue ArgumentError, TypeError
          1.year.ago
        end

        def paginated_messages(chat, before_id:, per:)
          scope = admin_chat_message_id_scope(chat)
          scope = scope.where("chat_messages.id < ?", before_id) if before_id

          ids = scope.reorder(id: :desc).limit(per + 1).pluck(:id)
          has_more_older = ids.size > per
          ids = ids.first(per)
          messages_by_id = ChatMessage.includes(:bookmarks, :proposal).where(id: ids).index_by(&:id)

          [ ids.reverse.filter_map { |id| messages_by_id[id] }, has_more_older ]
        end

        def admin_chat_message_id_scope(chat)
          scope = ChatMessage.where(chat_session_id: chat.id)
          return scope unless mysql_adapter?

          scope.from(Arel.sql("#{ChatMessage.quoted_table_name} FORCE INDEX (index_chat_messages_on_session_id_and_id)"))
        end

        def mysql_adapter?
          ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
        end

        def serialize_compact(chat, include_message_count: true)
          payload = {
            id: chat.id,
            title: chat.title,
            user: user_payload(chat.user),
            repositories: attached_repositories(chat).map { |repository| repository_payload(repository) },
            last_message_at: chat.last_message_at,
            stop_requested_at: chat.stop_requested_at,
            cumulative_input_tokens: chat.cumulative_input_tokens.to_i,
            cumulative_output_tokens: chat.cumulative_output_tokens.to_i,
            cumulative_cost_usd: chat.cumulative_cost.to_f,
            created_at: chat.created_at,
            updated_at: chat.updated_at
          }
          payload[:messages_count] = chat.respond_to?(:messages_count) ? chat.messages_count.to_i : chat.messages.count if include_message_count
          payload
        end

        def serialize_chat(chat)
          serialize_compact(chat, include_message_count: false).merge(
            workspace_path: chat.workspace_path,
            attachments: chat.chat_attachments.order(:attached_at, :id).map { |attachment| attachment_payload(attachment) },
            bookmarks: chat.bookmarks.map { |bookmark| bookmark_payload(bookmark) },
            proposals: chat.proposals.order(:created_at, :id).map { |proposal| proposal_payload(proposal) },
            turn_in_flight: chat.turn_in_flight?,
            agent_busy: chat.agent_busy?
          )
        end

        def serialize_message(message)
          {
            id: message.id,
            role: message.role,
            tool_name: message.tool_name,
            tool_use_id: message.tool_use_id,
            content: message.content,
            proposal: message.proposal ? proposal_payload(message.proposal) : nil,
            bookmarks: message.bookmarks.map { |bookmark| bookmark_payload(bookmark) },
            created_at: message.created_at,
            updated_at: message.updated_at
          }
        end

        def attachment_payload(attachment)
          record = attachment.attachable
          {
            id: attachment.id,
            type: attachment.attachable_type,
            attachable_id: attachment.attachable_id,
            label: attachment_label(record),
            attached_at: attachment.attached_at
          }
        end

        def attached_repositories(chat)
          chat.chat_attachments.filter_map do |attachment|
            attachment.attachable if attachment.attachable_type == "Repository"
          end
        end

        def attachment_label(record)
          case record
          when Repository
            record.slug
          when Job
            record.slug
          when Epic
            record.slug
          when Document
            record.title
          else
            record&.to_s
          end
        end

        def bookmark_payload(bookmark)
          {
            id: bookmark.id,
            label: bookmark.label,
            kind: bookmark.kind,
            message_id: bookmark.chat_message_id,
            anchor: "message-#{bookmark.chat_message_id}",
            created_at: bookmark.created_at
          }
        end

        def proposal_payload(proposal)
          {
            id: proposal.id,
            slug: proposal.slug,
            kind: proposal.kind,
            state: proposal.state,
            title: proposal.title,
            repository: proposal.repository&.slug,
            job_id: proposal.job_id,
            epic_id: proposal.epic_id,
            parent_proposal_id: proposal.parent_proposal_id,
            created_at: proposal.created_at,
            updated_at: proposal.updated_at
          }
        end

        def repository_payload(repository)
          {
            id: repository.id,
            slug: repository.slug,
            default_branch: repository.default_branch
          }
        end

        def user_payload(user)
          {
            id: user.id,
            email_address: user.email_address,
            admin: user.admin?
          }
        end
      end
    end
  end
end
