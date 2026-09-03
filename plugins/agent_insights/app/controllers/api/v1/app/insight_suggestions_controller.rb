module Api
  module V1
    module App
      class InsightSuggestionsController < BaseController
        include RepositoryTabsSerialization
        include ChatSessionLifecycle
        include ChatLockErrors
        include Paginatable
        prepend_before_action :require_agent_insights_feature

        PER_PAGE = 20
        STATES = %w[pending accepted dismissed retired all].freeze

        def run_insight_analysis
          unless AgentInsights.enabled?
            render_error("agent_insights_disabled", "Agent Insights is not enabled.", status: :not_found)
            return
          end

          repository = find_repository

          if repository.jobs.where(kind: "agent_insight").where.not(state: "closed").exists?
            render json: { message: "An insight analysis job is already running for #{repository.slug}.", started: false }
            return
          end

          user = Current.user
          job = Job.transaction do
            j = user.jobs.create!(
              repository: repository,
              kind: "agent_insight",
              issue_number: nil,
              issue_title: "Insight analysis: #{repository.slug}",
              owner_user: user
            )
            WorkUnits::Launcher.create_and_start!(kind: "agent_insight", job: j)
            j
          end

          render json: { message: "Insight analysis started for #{repository.slug}.", started: true, job_id: job.id }
        end

        def index
          repository = find_repository
          return unless repository

          AgentInsights::Suggestion.resolve_obsolete_remove_memory!(AgentInsights::Suggestion.for_repository(repository))

          page     = page_param
          per_page = per_page_param
          state    = state_param

          base_relation = AgentInsights::Suggestion.for_repository(repository)
            .includes(:job, :created_job)
            .order(Arel.sql("CASE severity WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, confidence DESC"))

          relation    = state == "all" ? base_relation : base_relation.where(state: state)
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
              total_pages: total_pages,
              state:       state,
              counts:      state_counts(AgentInsights::Suggestion.for_repository(repository))
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

        def discuss
          suggestion = find_suggestion_for_discussion
          return unless suggestion

          chat_session = nil
          user_message = nil

          ApplicationRecord.transaction do
            chat_session = ChatSession.create!(
              user: Current.user,
              repository: suggestion.repository,
              title: nil,
              last_message_at: Time.current
            )
            user_message = chat_session.messages.create!(
              role: "user",
              content: { "text" => insight_discussion_message(suggestion) }
            )
            chat_session.pin_chat_provider!
          end

          enqueue_chat_title(chat_session, user_message)
          enqueue_chat_turn(chat_session, user_message)

          render json: { redirect_to: chat_path(chat_session) }, status: :created
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::StatementTimeout, SolidQueue::Job::EnqueueError => e
          raise unless transient_chat_lock_error?(e)

          render_temporary_chat_lock_error
        end

        private

        def state_param
          state = params[:state].to_s
          STATES.include?(state) ? state : "all"
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

        def suggestion_counts(repository)
          state_counts(AgentInsights::Suggestion.for_repository(repository)).transform_keys(&:to_s)
        end

        def require_agent_insights_feature
          render_error("agent_insights_disabled", "Agent Insights is not enabled.", status: :not_found) unless AgentInsights.enabled?
        end

        def find_repository
          # run_insight_analysis is routed with :id; the listing routes use
          # :repository_id.
          repo = Repository.accessible_to(Current.user).find_by(id: params[:repository_id] || params[:id])
          unless repo
            render_error("not_found", "Repository not found.", status: :not_found)
            return nil
          end
          repo
        end

        def find_suggestion
          suggestion = if Current.user.admin?
            AgentInsights::Suggestion.find_by(id: params[:id])
          else
            AgentInsights::Suggestion
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

        def find_suggestion_for_discussion
          suggestion = AgentInsights::Suggestion
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
          result = AgentInsights::Proposals::Base.for(suggestion).accept!(actor: Current.user, params: params)
          unless result&.ok?
            render_error("validation_failed", result&.message || "AgentInsights::Suggestion could not be accepted.", status: :unprocessable_content)
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
            render_error("validation_failed", "AgentInsights::Suggestion cannot be dismissed (already accepted or dismissed).", status: :unprocessable_content)
            return
          end

          render json: {
            message: "AgentInsights::Suggestion dismissed.",
            suggestion: suggestion_json(suggestion.reload)
          }
        end

        def handle_undismiss(suggestion)
          unless suggestion.undismiss!
            render_error("validation_failed", "AgentInsights::Suggestion cannot be undismissed (not currently dismissed).", status: :unprocessable_content)
            return
          end

          render json: {
            message: "AgentInsights::Suggestion restored to pending.",
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

          memory = AgentMemory::Entry.create!(user: Current.user, 
            kind: "project_fact",
            scope: "repository",
            scope_id: repository.id,
            content: suggestion.redacted_memory_suggestion,
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
            job_id = entry["job_id"].presence&.to_i
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

        def insight_discussion_message(suggestion)
          details = [
            "I want to discuss this repository insight before deciding whether to accept or dismiss it.",
            "",
            "Title: #{suggestion.redacted_title}",
            "Severity: #{suggestion.severity}",
            "Category: #{suggestion.redacted_category}",
            "Confidence: #{suggestion.confidence}",
            "Proposal type: #{suggestion.effective_proposal_type}"
          ]

          if suggestion.suggested_prompt.present?
            details.concat([ "", "Suggested prompt:", suggestion.redacted_suggested_prompt ])
          end
          if suggestion.memory_suggestion.present?
            details.concat([ "", "Memory suggestion:", suggestion.redacted_memory_suggestion ])
          end

          evidence_lines = insight_evidence_lines(suggestion)
          details.concat([ "", "Evidence:", *evidence_lines ]) if evidence_lines.any?

          details.join("\n")
        end

        def insight_evidence_lines(suggestion)
          evidence_json(suggestion.evidence).filter_map do |entry|
            links = []
            links << "#{::App::Presentation.job_slug(entry[:job_id])}: #{entry[:job_path]}" if entry[:job_path]
            links << "run transcript #{entry[:run_id]}: #{entry[:run_transcript_path]}" if entry[:run_transcript_path]
            next if links.empty?

            "- #{[ entry[:kind], *links ].compact.join(" - ")}"
          end
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
