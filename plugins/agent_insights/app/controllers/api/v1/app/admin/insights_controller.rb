module Api
  module V1
    module App
      module Admin
        class InsightsController < BaseController
          include Paginatable

          prepend_before_action :require_agent_insights_feature
          before_action :require_admin

          PER_PAGE = 20
          STATES = %w[pending accepted dismissed retired all].freeze
          SORTS = {
            "title" => [ "agent_insight_suggestions.title" ],
            "repository" => [ "repositories.owner", "repositories.name" ],
            "user" => [ "users.display_name" ],
            "severity" => [ "CASE agent_insight_suggestions.severity WHEN 'high' THEN 2 WHEN 'medium' THEN 1 ELSE 0 END" ],
            "confidence" => [ "agent_insight_suggestions.confidence" ],
            "state" => [ "agent_insight_suggestions.state" ],
            "created" => [ "agent_insight_suggestions.created_at" ]
          }.freeze

          def index
            AgentInsights::Suggestion.resolve_obsolete_remove_memory!

            page     = page_param
            per_page = per_page_param

            base_relation = AgentInsights::Suggestion
              .left_outer_joins(:repository, job: :user)
              .includes(:repository, :created_job, job: :user)

            filter      = current_filter
            relation    = order_relation(filter.apply(base_relation))
            total       = relation.count
            total_pages = [ (total.to_f / per_page).ceil, 1 ].max
            suggestions = relation.offset((page - 1) * per_page).limit(per_page)
            count_relation = current_filter(active_folder: nil, raw_params: count_filter_params).apply(AgentInsights::Suggestion.all)

            render json: {
              suggestions: suggestions.map { |s| admin_suggestion_json(s) },
              filter: filter.to_h,
              filter_schema: AgentInsights::Filter.schema,
              active_smart_folder_id: active_smart_folder&.id,
              smart_folders: smart_folders,
              meta: {
                total:       total,
                page:        page,
                per_page:    per_page,
                total_pages: total_pages,
                state:       legacy_state_for_meta,
                counts:      state_counts(count_relation)
              }
            }
          end

          def promote_memory
            suggestion = AgentInsights::Suggestion.find_by(id: params[:id])
            unless suggestion
              render_error("not_found", "Insight suggestion not found.", status: :not_found)
              return
            end

            if suggestion.memory_suggestion.blank?
              render_error("validation_failed", "No memory suggestion available.", status: :unprocessable_content)
              return
            end

            memory = AgentMemory::Entry.create!(user: suggestion.job.user,
              kind: "project_fact",
              scope: "instance",
              scope_id: nil,
              content: suggestion.redacted_memory_suggestion,
              source_type: "insight",
              source_id: suggestion.id,
              author: "admin",
              confidence: suggestion.confidence
            )

            render json: {
              message: "Memory promoted to instance scope.",
              memory_id: memory.id
            }
          end

          private

          def current_filter(active_folder: self.active_smart_folder, raw_params: params)
            smart_folder = AgentInsights::Filter.smart_folder_floor(raw_params, active_folder, user: Current.user)
            AgentInsights::Filter.from_params(raw_params, smart_folder: smart_folder, user: Current.user)
          end

          def active_smart_folder
            @active_smart_folder ||= begin
              explicit_folder = ::Admin::SmartFolderNavigation.active_folder(
                subject: AgentInsights::SmartFolders::SUBJECT,
                user: Current.user,
                params: params
              )
              explicit_folder || default_smart_folder
            end
          end

          def default_smart_folder
            return if smart_folder_param_present?
            return if params[::Filters::QueryParam::PARAM_NAME].present?
            return if params[:state].present?

            AgentInsights::SmartFolders.default_folder
          end

          def smart_folder_param_present?
            params.key?(:smart_folder_id) || params.key?("smart_folder_id")
          end

          def count_filter_params
            params.except(:smart_folder_id, "smart_folder_id", :state, "state")
          end

          def smart_folders
            ::SmartFolder.ensure_builtins_for_subject!(AgentInsights::SmartFolders::SUBJECT)
            ::Admin::SmartFolderNavigation.new(
              subject: AgentInsights::SmartFolders::SUBJECT,
              user: Current.user,
              active_folder: active_smart_folder,
              base_scope: AgentInsights::Suggestion.all,
              filter_class: AgentInsights::Filter
            ).folders.map do |folder|
              folder.merge(path: folder.fetch(:path).sub(%r{\A/agent_insights}, "/admin/insights"))
            end
          end

          def legacy_state_for_meta
            state = params[:state].to_s
            STATES.include?(state) ? state : active_smart_folder&.name&.downcase.presence_in(STATES) || "all"
          end

          def state_counts(relation)
            counts = relation.group(:state).count
            {
              pending:   counts.fetch("pending", 0),
              accepted:  counts.fetch("accepted", 0),
              dismissed: counts.fetch("dismissed", 0),
              retired:   counts.fetch("retired", 0),
              all:       counts.values.sum
            }
          end

          def order_relation(scope)
            columns = SORTS.fetch(sort_param, SORTS.fetch("severity"))
            ordered_columns = columns.map { |column| "#{column} #{direction.upcase}" }
            ordered_columns << "agent_insight_suggestions.created_at DESC"
            ordered_columns << "agent_insight_suggestions.id DESC"
            scope.order(Arel.sql(ordered_columns.join(", ")))
          end

          def sort_param
            SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : "severity"
          end

          def direction
            params[:direction].to_s == "asc" ? "asc" : "desc"
          end

          def require_agent_insights_feature
            render_error("agent_insights_disabled", "Agent Insights is not enabled.", status: :not_found) unless AgentInsights.enabled?
          end

          def admin_suggestion_json(suggestion)
            {
              id: suggestion.id,
              slug: "INSIGHT-#{suggestion.id}",
              title: suggestion.redacted_title,
              category: suggestion.redacted_category,
              severity: suggestion.severity,
              confidence: suggestion.confidence,
              state: suggestion.state,
              proposal_type: suggestion.effective_proposal_type,
              suggested_prompt: suggestion.redacted_suggested_prompt,
              memory_suggestion: suggestion.redacted_memory_suggestion,
              has_memory_suggestion: suggestion.memory_suggestion.present?,
              target_memory_id: suggestion.target_memory_id,
              stale_memory_text: suggestion.redacted_stale_memory_text,
              stale_memory_evidence: suggestion.redacted_stale_memory_evidence,
              target_insight_id: suggestion.target_insight_id,
              retired_reason: suggestion.redacted_retired_reason,
              superseded_by_insight_id: suggestion.superseded_by_insight_id,
              superseded_by_job_id: suggestion.superseded_by_job_id,
              superseded_by_job_slug: suggestion.superseded_by_job&.slug,
              evidence: evidence_json(suggestion.redacted_evidence),
              repository: {
                id: suggestion.repository.id,
                slug: suggestion.repository.slug,
                repository_path: repository_path(suggestion.repository),
                insights_path: "/repositories/#{suggestion.repository.id}/plugin/insights"
              },
              user: {
                id: suggestion.job.user_id,
                display_name: suggestion.job.user.display_name
              },
              job_slug: suggestion.job.slug,
              job_path: job_path(suggestion.job),
              accepted_at: suggestion.accepted_at,
              dismissed_at: suggestion.dismissed_at,
              retired_at: suggestion.retired_at,
              created_at: suggestion.created_at,
              created_job: suggestion.created_job ? created_job_summary_json(suggestion.created_job) : nil
            }
          end

          def evidence_json(evidence)
            return [] unless evidence.is_a?(Array)

            evidence.map do |entry|
              next unless entry.is_a?(Hash)
              job_id = entry["job_id"]
              run_id = entry["run_id"]
              {
                job_id: job_id,
                run_id: run_id,
                kind: entry["kind"],
                job_path: job_id ? "/jobs/#{job_id}" : nil,
                run_transcript_path: run_id ? "/admin/runs/#{run_id}/transcript" : nil
              }
            end.compact
          end

          def created_job_summary_json(job)
            {
              id: job.id,
              slug: job.slug,
              title: job.issue_title,
              state: job.state,
              job_path: job_path(job)
            }
          end
        end
      end
    end
  end
end
