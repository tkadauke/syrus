module Api
  module V1
    module App
      class InsightSuggestionsController < BaseController
        include RepositoryTabsSerialization
        prepend_before_action :require_agent_insights_feature

        PER_PAGE = 20

        def index
          repository = find_repository
          return unless repository

          page     = page_param
          per_page = per_page_param
          state    = state_param

          base_relation = repository.insight_suggestions
            .includes(:job, :created_job)
            .order(Arel.sql("CASE severity WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, confidence DESC"))

          relation = state == "all" ? base_relation : base_relation.where(state: state)

          total       = relation.count
          total_pages = [ (total.to_f / per_page).ceil, 1 ].max
          suggestions = relation.offset((page - 1) * per_page).limit(per_page)

          render json: {
            repository: repository_summary_json(repository),
            tabs: repository_tabs_json(repository),
            counts: suggestion_counts(repository),
            suggestions: suggestions.map { |s| suggestion_json(s) },
            meta: {
              total:       total,
              page:        page,
              per_page:    per_page,
              total_pages: total_pages
            }
          }
        end

        def update
          suggestion = find_suggestion
          return unless suggestion

          case params[:action_type]
          when "accept"
            handle_accept(suggestion)
          when "dismiss"
            handle_dismiss(suggestion)
          when "undismiss"
            handle_undismiss(suggestion)
          when "save_memory"
            handle_save_memory(suggestion)
          else
            render_error("validation_failed", "Unknown action.", status: :unprocessable_content)
          end
        end

        private

        def page_param
          page = params[:page].to_i
          page.positive? ? page : 1
        end

        def per_page_param
          per_page = params[:per_page].to_i
          return PER_PAGE unless per_page.positive?
          [ per_page, 100 ].min
        end

        def state_param
          state = params[:state].to_s
          return state if InsightSuggestion::STATES.include?(state) || state == "all"

          "all"
        end

        def suggestion_counts(repository)
          grouped = repository.insight_suggestions.group(:state).count
          counts = InsightSuggestion::STATES.index_with { |state| grouped[state] || 0 }
          counts.merge("all" => counts.values.sum)
        end

        def require_agent_insights_feature
          render_error("agent_insights_disabled", "Agent Insights is not enabled.", status: :not_found) unless Feature.agent_insights_enabled?
        end

        def find_repository
          repo = Current.user.repositories.find_by(id: params[:repository_id])
          unless repo
            render_error("not_found", "Repository not found.", status: :not_found)
            return nil
          end
          repo
        end

        def find_suggestion
          suggestion = if Current.user.admin?
                         InsightSuggestion.find_by(id: params[:id])
                       else
                         InsightSuggestion
                           .joins(:repository)
                           .where(repositories: { id: Current.user.repositories.select(:id) })
                           .find_by(id: params[:id])
                       end

          unless suggestion
            render_error("not_found", "Insight suggestion not found.", status: :not_found)
            return nil
          end
          suggestion
        end

        def handle_accept(suggestion)
          result = InsightSuggestions::Proposals::Base.for(suggestion).accept!(actor: Current.user, params: params)
          unless result&.ok?
            render_error("validation_failed", result&.message || "Suggestion could not be accepted.", status: :unprocessable_content)
            return
          end

          render json: {
            message: result.message,
            suggestion: suggestion_json(result.suggestion),
            job: result.job ? created_job_summary_json(result.job) : nil,
            memory_id: result.memory&.id
          }
        end

        def handle_dismiss(suggestion)
          unless suggestion.dismiss!
            render_error("validation_failed", "Suggestion cannot be dismissed (already accepted or dismissed).", status: :unprocessable_content)
            return
          end

          render json: {
            message: "Suggestion dismissed.",
            suggestion: suggestion_json(suggestion.reload)
          }
        end

        def handle_undismiss(suggestion)
          unless suggestion.undismiss!
            render_error("validation_failed", "Suggestion cannot be undismissed (not currently dismissed).", status: :unprocessable_content)
            return
          end

          render json: {
            message: "Suggestion restored to pending.",
            suggestion: suggestion_json(suggestion.reload)
          }
        end

        def handle_save_memory(suggestion)
          if suggestion.memory_suggestion.blank?
            render_error("validation_failed", "No memory suggestion available.", status: :unprocessable_content)
            return
          end

          repository = suggestion.repository
          unless Current.user.repositories.exists?(id: repository.id)
            render_error("forbidden", "Repository not accessible.", status: :forbidden)
            return
          end

          memory = Current.user.chat_memories.create!(
            kind: "project_fact",
            scope: "repository",
            scope_id: repository.id,
            content: suggestion.memory_suggestion,
            source_type: "insight",
            source_id: suggestion.id,
            author: "agent",
            confidence: suggestion.confidence
          )

          render json: {
            message: "Memory saved.",
            suggestion: suggestion_json(suggestion),
            memory_id: memory.id
          }
        end

        def suggestion_json(suggestion)
          {
            id: suggestion.id,
            title: suggestion.title,
            category: suggestion.category,
            severity: suggestion.severity,
            confidence: suggestion.confidence,
            state: suggestion.state,
            proposal_type: suggestion.effective_proposal_type,
            suggested_prompt: suggestion.suggested_prompt,
            memory_suggestion: suggestion.memory_suggestion,
            has_memory_suggestion: suggestion.memory_suggestion.present?,
            target_memory_id: suggestion.target_memory_id,
            stale_memory_text: suggestion.stale_memory_text,
            stale_memory_evidence: suggestion.stale_memory_evidence,
            target_insight_id: suggestion.target_insight_id,
            evidence: evidence_json(suggestion.evidence),
            job_slug: suggestion.job.slug,
            job_path: job_path(suggestion.job),
            accepted_at: suggestion.accepted_at,
            dismissed_at: suggestion.dismissed_at,
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

        def repository_summary_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            repository_path: repository_path(repository),
            insights_path: "/repositories/#{repository.id}/insights"
          }
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
