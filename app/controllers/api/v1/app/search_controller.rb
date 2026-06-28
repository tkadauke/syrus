module Api
  module V1
    module App
      class SearchController < BaseController
        TYPES = %w[job epic chat].freeze
        DEFAULT_LIMIT = 30
        MAX_LIMIT = 100
        CHAT_GROUPED_MATCH_LIMIT = 3

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
          rows = grouped_chat_rows(rows)
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
            merge_slug_rows(
              JobSearchIndex.search(query, user_id: Current.user.id, limit: limit),
              job_slug_rows(query)
            ).first(limit)
          when "epic"
            merge_slug_rows(
              EpicSearchIndex.search(query, user_id: Current.user.id, limit: limit),
              epic_slug_rows(query)
            ).first(limit)
          when "chat"
            ChatMessageSearchIndex.search(query, user_id: Current.user.id, limit: limit)
          end
        end

        def merge_slug_rows(search_rows, slug_rows)
          return search_rows if slug_rows.empty?

          existing_ids = search_rows.each_with_object([]) do |row, ids|
            ids << slug_row_id(row)
          end

          slug_rows.reject { |row| existing_ids.include?(slug_row_id(row)) } + search_rows
        end

        def slug_row_id(row)
          (row[:job_id] || row[:epic_id]).to_i
        end

        def job_slug_rows(query)
          job_ids = query.scan(/\bJOB-(\d+)\b/i).flatten.map(&:to_i).uniq
          return [] if job_ids.empty?

          Current.user.jobs.where(id: job_ids).map do |job|
            {
              job_id: job.id,
              rank: -1.0,
              snippet: "<mark>#{ERB::Util.html_escape(::App::Presentation.job_slug(job))}</mark>"
            }
          end
        end

        def epic_slug_rows(query)
          epic_numbers = query.scan(/\bEPIC-(\d+)\b/i).flatten.map(&:to_i).uniq
          return [] if epic_numbers.empty?

          Current.user.epics.where(number: epic_numbers).map do |epic|
            {
              epic_id: epic.id,
              rank: -1.0,
              snippet: "<mark>#{ERB::Util.html_escape(epic.display_number)}</mark>"
            }
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
          payload = {
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
          if row.key?(:grouped_matches)
            payload[:grouped_matches] = row.fetch(:grouped_matches).filter_map { |match_row| chat_grouped_match_json(match_row) }
            payload[:total_match_count] = row.fetch(:total_match_count)
            payload[:has_more_matches] = row.fetch(:has_more_matches)
          end
          payload
        end

        def chat_grouped_match_json(row)
          message = chat_messages_by_id[row.fetch(:chat_message_id).to_i]
          return unless message

          {
            id: message.id,
            snippet: row.fetch(:snippet),
            path: chat_path(message.chat_session, message_id: message.id),
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
              row.fetch(:grouped_matches, []).each do |match_row|
                match_value = match_row[key]
                ids << match_value.to_i if match_value.present?
              end
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

        def grouped_chat_rows(rows)
          chat_rows_by_session = {}
          grouped_session_ids = []

          rows.filter_map do |row|
            next row unless row.fetch(:type) == "chat"

            chat_session_id = row[:chat_session_id]
            next row if chat_session_id.blank?

            chat_session_id = chat_session_id.to_i
            grouped_session_ids << chat_session_id unless chat_rows_by_session.key?(chat_session_id)
            chat_rows_by_session[chat_session_id] ||= []
            chat_rows_by_session[chat_session_id] << row
            nil
          end + grouped_session_ids.map { |chat_session_id| grouped_chat_row(chat_rows_by_session.fetch(chat_session_id)) }
        end

        def grouped_chat_row(rows)
          representative, *additional_matches = rows
          representative.merge(
            grouped_matches: additional_matches.first(CHAT_GROUPED_MATCH_LIMIT),
            total_match_count: rows.length,
            has_more_matches: additional_matches.length > CHAT_GROUPED_MATCH_LIMIT
          )
        end
      end
    end
  end
end
