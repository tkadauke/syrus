module Api
  module V1
    module App
      class AgentQuestionsController < BaseController
        def index
          scope = visible_questions
          scope = scope.where(runs: { job_id: params[:job_id] }) if params[:job_id].present?
          render json: { questions: scope.limit(100).map { |question| question_json(question) } }
        end

        def answer
          question = visible_questions.find(params[:id])
          if question.answer!(answers: agent_question_answers_param, answered_by: Current.user, source: "web")
            render json: { message: I18n.t("agent_questions.answered") }
          else
            render_error("invalid_answers", I18n.t("agent_questions.errors.answers_malformed"), status: :unprocessable_content)
          end
        end

        private

        def agent_question_answers_param
          raw = params[:answers]
          return [] unless raw.is_a?(Array) || raw.is_a?(ActionController::Parameters)

          entries = raw.is_a?(ActionController::Parameters) ? raw.values : raw
          entries.map do |entry|
            if entry.is_a?(Array) || entry.is_a?(ActionController::Parameters)
              values = entry.is_a?(ActionController::Parameters) ? entry.values : entry
              values.map(&:to_s)
            else
              entry.to_s
            end
          end
        end

        def visible_questions
          AgentQuestion.active.where.not(run_id: nil).joins(run: :job).merge(Job.visible_to(Current.user)).preload(run: { job: :repository })
        end

        def question_json(question)
          job = question.run.job
          {
            id: question.id,
            job_id: job.id,
            job_slug: job.slug,
            job_title: job.issue_title,
            repository_slug: job.repository.slug,
            asked_at: question.asked_at&.iso8601,
            times_out_at: question.times_out_at&.iso8601,
            questions: question.questions_payload,
            app_answer_path: "/api/v1/app/agent_questions/#{question.id}/answer",
            job_path: "/jobs/#{job.id}"
          }
        end
      end
    end
  end
end
