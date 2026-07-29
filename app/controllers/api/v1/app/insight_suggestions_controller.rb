module Api
  module V1
    module App
      class InsightSuggestionsController < BaseController
        include RepositoryTabsSerialization
        prepend_before_action :require_agent_insights_feature

        def index
          repository = find_repository
          return unless repository

          suggestions = repository.insight_suggestions
            .includes(:job, :created_job)
            .order(Arel.sql("CASE severity WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, confidence DESC"))

          render json: {
            repository: repository_summary_json(repository),
            tabs: repository_tabs_json(repository),
            suggestions: suggestions.map { |s| suggestion_json(s) }
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
          when "save_memory"
            handle_save_memory(suggestion)
          else
            render_error("validation_failed", "Unknown action.", status: :unprocessable_content)
          end
        end

        private

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
          suggestion = InsightSuggestion
            .joins(:repository)
            .where(repositories: { id: Current.user.repositories.select(:id) })
            .find_by(id: params[:id])

          unless suggestion
            render_error("not_found", "Insight suggestion not found.", status: :not_found)
            return nil
          end
          suggestion
        end

        def handle_accept(suggestion)
          created_job = nil

          if ActiveModel::Type::Boolean.new.cast(params[:create_job])
            prompt_text = params[:prompt].to_s.strip
            if prompt_text.blank?
              render_error("validation_failed", "Prompt can't be blank when creating a job.", status: :unprocessable_content)
              return
            end

            repository = suggestion.repository
            agent_provider = params[:agent_provider].to_s.presence || repository.effective_agent_provider

            created_job = Current.user.jobs.create!(
              repository: repository,
              kind: "direct",
              issue_number: nil,
              issue_title: suggestion.title.truncate(120),
              title_pending: false,
              issue_body: prompt_text,
              agent_provider: agent_provider,
              priority: "medium",
              state: Job.initial_state_for_creator(Current.user)
            )
            created_job.advance_after_triage! if created_job.may_advance_after_triage?
          end

          unless suggestion.accept!(created_job: created_job)
            render_error("validation_failed", "Suggestion cannot be accepted (already accepted or dismissed).", status: :unprocessable_content)
            return
          end

          render json: {
            message: "Suggestion accepted.",
            suggestion: suggestion_json(suggestion.reload),
            job: created_job ? created_job_summary_json(created_job) : nil
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
            suggested_prompt: suggestion.suggested_prompt,
            memory_suggestion: suggestion.memory_suggestion,
            has_memory_suggestion: suggestion.memory_suggestion.present?,
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
