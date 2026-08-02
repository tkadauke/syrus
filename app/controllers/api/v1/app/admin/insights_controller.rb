module Api
  module V1
    module App
      module Admin
        class InsightsController < BaseController
          prepend_before_action :require_agent_insights_feature
          before_action :require_admin

          PER_PAGE = 20

          def index
            page     = page_param
            per_page = per_page_param

            relation = InsightSuggestion
              .includes(:job, :repository, :created_job)
              .order(Arel.sql("CASE severity WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, confidence DESC, insight_suggestions.created_at DESC"))

            total       = relation.count
            total_pages = [ (total.to_f / per_page).ceil, 1 ].max
            suggestions = relation.offset((page - 1) * per_page).limit(per_page)

            render json: {
              suggestions: suggestions.map { |s| admin_suggestion_json(s) },
              meta: {
                total:       total,
                page:        page,
                per_page:    per_page,
                total_pages: total_pages
              }
            }
          end

          def promote_memory
            suggestion = InsightSuggestion.find_by(id: params[:id])
            unless suggestion
              render_error("not_found", "Insight suggestion not found.", status: :not_found)
              return
            end

            if suggestion.memory_suggestion.blank?
              render_error("validation_failed", "No memory suggestion available.", status: :unprocessable_content)
              return
            end

            memory = suggestion.job.user.chat_memories.create!(
              kind: "project_fact",
              scope: "instance",
              scope_id: nil,
              content: suggestion.memory_suggestion,
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

          def page_param
            page = params[:page].to_i
            page.positive? ? page : 1
          end

          def per_page_param
            per_page = params[:per_page].to_i
            return PER_PAGE unless per_page.positive?
            [ per_page, 100 ].min
          end

          def require_agent_insights_feature
            render_error("agent_insights_disabled", "Agent Insights is not enabled.", status: :not_found) unless Feature.agent_insights_enabled?
          end

          def admin_suggestion_json(suggestion)
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
              repository: {
                id: suggestion.repository.id,
                slug: suggestion.repository.slug,
                repository_path: repository_path(suggestion.repository),
                insights_path: "/repositories/#{suggestion.repository.id}/insights"
              },
              user: {
                id: suggestion.job.user_id,
                display_name: suggestion.job.user.display_name
              },
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
