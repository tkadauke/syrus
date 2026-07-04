module Api
  module V1
    module App
      class PendingFeedbackController < BaseController
        def index
          job = find_job
          comments = pending_comments(job)
          render json: {
            job_id: job.id,
            feedback_policy: job.repository.feedback_policy,
            comments: comments.map { |c| comment_json(c) }
          }
        end

        def apply
          job = find_job
          comment = find_pending_comment(job)
          return unless comment

          result = ChatFeedbackSubmission.call(
            job: job,
            feedback: comment.body.to_s,
            allowed_states: %w[implemented failed],
            extra_artifacts: feedback_source_artifacts(comment, "apply")
          )

          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          comment.mark_actioned!(by: "operator:apply")

          render json: {
            message: "Feedback applied.",
            workflow: { id: result.workflow.id, state: result.workflow.state }
          }, status: :created
        end

        def ignore
          job = find_job
          comment = find_pending_comment(job)
          return unless comment

          comment.mark_actioned!(by: "operator:ignore")
          render json: ::App::JobDetailPayload.build(job: job.reload, user: Current.user)
        end

        def replace
          job = find_job
          comment = find_pending_comment(job)
          return unless comment

          body = params[:body].to_s.strip
          if body.blank?
            render_error("validation_failed", "Replacement text can't be blank.", status: :unprocessable_content)
            return
          end

          result = ChatFeedbackSubmission.call(
            job: job,
            feedback: body,
            allowed_states: %w[implemented failed],
            extra_artifacts: feedback_source_artifacts(comment, "replace")
          )

          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          comment.mark_actioned!(by: "operator:replace")

          render json: {
            message: "Feedback applied with replacement text.",
            workflow: { id: result.workflow.id, state: result.workflow.state }
          }, status: :created
        end

        private

        def find_job
          Current.user.jobs.find(params[:job_id])
        end

        def find_pending_comment(job)
          comment = pending_comments(job).find_by(id: params[:id])
          unless comment
            render_error("not_found", "Comment not found or already actioned.", status: :not_found)
            return nil
          end
          comment
        end

        def pending_comments(job)
          job.pr_review_comments
             .actionable_comments
             .unactioned
             .where.not(attributed_to: "job_owner")
             .order(:comment_created_at, :id)
        end

        def comment_json(comment)
          {
            id: comment.id,
            github_handle: comment.github_handle,
            attributed_to: comment.attributed_to,
            pr_type: comment.pr_type,
            comment_kind: comment.comment_kind,
            body: comment.body,
            comment_created_at: comment.comment_created_at&.iso8601
          }
        end

        def feedback_source_artifacts(comment, action)
          {
            "feedback_source" => {
              "pr_review_comment_id" => comment.id,
              "attributed_to" => comment.attributed_to,
              "github_handle" => comment.github_handle,
              "action" => action,
              "confirmed_by" => "operator"
            }
          }
        end
      end
    end
  end
end
