module Api
  module V1
    module App
      class SearchController < BaseController
        TYPES = %w[job epic chat].freeze
        DEFAULT_LIMIT = 30
        MAX_LIMIT = 100

        def index
          query = params[:q].to_s.strip
          if query.length < 2
            render_error("bad_request", "q must be at least 2 characters.", status: :bad_request)
            return
          end

          selected_types = search_types
          unless selected_types
            render_error("bad_request", "types must include only job, epic, or chat.", status: :bad_request)
            return
          end

          limit = search_limit
          rows = selected_types.flat_map { |type| normalized_rows(type, query, limit) }
          rows.sort_by! { |row| [ row.fetch(:rank), row.fetch(:type_order), row.fetch(:ordinal) ] }
          @search_result_rows = rows

          render json: rows.filter_map { |row| result_json(row) }.first(limit)
        end

        private

        def search_types
          raw_types = Array.wrap(params[:types]).compact_blank
          raw_types = TYPES if raw_types.empty?
          raw_types = raw_types.map(&:to_s).uniq
          return unless (raw_types - TYPES).empty?

          raw_types
        end

        def search_limit
          params.fetch(:limit, DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
        end

        def normalized_rows(type, query, limit)
          rows = search_rows(type, query, limit)
          return [] if rows.empty?

          min_rank, max_rank = rows.map { |row| row.fetch(:rank).to_f }.minmax
          denominator = max_rank - min_rank

          rows.each_with_index.map do |row, index|
            normalized_rank = denominator.zero? ? 0.0 : (row.fetch(:rank).to_f - min_rank) / denominator
            row.merge(type: type, type_order: TYPES.index(type), rank: normalized_rank, ordinal: index)
          end
        end

        def search_rows(type, query, limit)
          case type
          when "job"
            JobSearchIndex.search(query, user_id: Current.user.id, limit: limit)
          when "epic"
            EpicSearchIndex.search(query, user_id: Current.user.id, limit: limit)
          when "chat"
            ChatMessageSearchIndex.search(query, user_id: Current.user.id, limit: limit)
          end
        end

        def result_json(row)
          case row.fetch(:type)
          when "job"
            job_result_json(row)
          when "epic"
            epic_result_json(row)
          when "chat"
            chat_result_json(row)
          end
        end

        def job_result_json(row)
          job = jobs_by_id[row.fetch(:job_id).to_i]
          return unless job

          {
            type: "job",
            id: job.id,
            title: job.issue_title.to_s,
            snippet: row.fetch(:snippet),
            rank: row.fetch(:rank),
            path: job_path(job),
            state: job.state,
            repository_slug: job.repository.slug,
            created_at: job.created_at&.iso8601
          }
        end

        def epic_result_json(row)
          epic = epics_by_id[row.fetch(:epic_id).to_i]
          return unless epic

          {
            type: "epic",
            id: epic.id,
            title: epic.title.to_s,
            snippet: row.fetch(:snippet),
            rank: row.fetch(:rank),
            path: epic_path(epic),
            state: epic.state,
            repository_slug: epic.repository.slug,
            created_at: epic.created_at&.iso8601
          }
        end

        def chat_result_json(row)
          message = chat_messages_by_id[row.fetch(:chat_message_id).to_i]
          return unless message

          chat_session = message.chat_session
          {
            type: "chat",
            id: message.id,
            title: chat_title(chat_session),
            snippet: row.fetch(:snippet),
            rank: row.fetch(:rank),
            path: chat_path(chat_session, message_id: message.id),
            state: nil,
            repository_slug: nil,
            created_at: message.created_at&.iso8601
          }
        end

        def jobs_by_id
          @jobs_by_id ||= Current.user.jobs.includes(:repository).where(id: result_ids(:job_id)).index_by(&:id)
        end

        def epics_by_id
          @epics_by_id ||= Current.user.epics.includes(:repository).where(id: result_ids(:epic_id)).index_by(&:id)
        end

        def chat_messages_by_id
          @chat_messages_by_id ||= ChatMessage
            .joins(:chat_session)
            .where(chat_sessions: { user_id: Current.user.id }, id: result_ids(:chat_message_id))
            .includes(chat_session: :attached_repositories)
            .index_by(&:id)
        end

        def result_ids(key)
          @result_ids ||= {}
          @result_ids[key] ||= begin
            ids = []
            search_result_rows.each do |row|
              value = row[key]
              ids << value.to_i if value.present?
            end
            ids
          end
        end

        def search_result_rows
          @search_result_rows ||= []
        end

        def chat_title(chat_session)
          chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository)
        end
      end
    end
  end
end
