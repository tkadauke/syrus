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

          comment.mark_handling_started!(workflow: result.workflow, by: "operator:apply")

          render json: {
            message: "Feedback applied.",
            workflow: { id: result.workflow.id, state: result.workflow.state }
          }, status: :created
        end

        def ignore
          job = find_job
          comment = find_pending_comment(job)
          return unless comment

          comment.mark_ignored!
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

          comment.mark_handling_started!(workflow: result.workflow, by: "operator:replace")

          render json: {
            message: "Feedback applied with replacement text.",
            workflow: { id: result.workflow.id, state: result.workflow.state }
          }, status: :created
        end

        def retry
          job = find_job
          comment = pending_comments(job).detect { |candidate| candidate.id == params[:id].to_i }
          unless comment&.retryable_handling?
            render_error("not_found", "Comment not found or not retryable.", status: :not_found)
            return
          end

          if active_feedback_workflow_for?(job, comment)
            render_error("conflict", "A feedback workflow is already queued or running for this comment.", status: :conflict)
            return
          end

          result = retry_feedback_handling(job, comment)
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          comment.mark_handling_started!(workflow: result.workflow, by: "operator:retry")

          render json: {
            message: "Retry addressing PR feedback started.",
            workflow: { id: result.workflow.id, state: result.workflow.state }
          }, status: :created
        end

        private

        def find_job
          Current.user.jobs.find(params[:job_id])
        end

        def find_pending_comment(job)
          comment = pending_comments(job).detect { |candidate| candidate.id == params[:id].to_i }
          unless comment
            render_error("not_found", "Comment not found or already actioned.", status: :not_found)
            return nil
          end
          comment
        end

        def pending_comments(job)
          job.pr_review_comments
             .actionable_comments
             .where.not(attributed_to: "job_owner")
             .order(:comment_created_at, :id)
             .select(&:pending_for_operator?)
        end

        def comment_json(comment)
          {
            id: comment.id,
            github_handle: comment.github_handle,
            attributed_to: comment.attributed_to,
            pr_type: comment.pr_type,
            comment_kind: comment.comment_kind,
            body: comment.body,
            comment_created_at: comment.comment_created_at&.iso8601,
            handling_state: comment.handling_state || "pending",
            handling_workflow_id: comment.handling_workflow_id,
            handling_failed_at: comment.handling_failed_at&.iso8601,
            handling_failure_reason: comment.handling_failure_reason,
            retryable: comment.retryable_handling?
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

        def active_feedback_workflow_for?(job, comment)
          job.workflows.active.where(trigger_kind: Workflow::TriggerKind.feedback_values).any? do |workflow|
            workflow_references_comment?(workflow, comment)
          end
        end

        def workflow_references_comment?(workflow, comment)
          Array(workflow.artifact("pr_review_comment_ids")).map(&:to_i).include?(comment.id) ||
            workflow.artifact("feedback_source").to_h["pr_review_comment_id"].to_i == comment.id
        end

        RETRY_TEMPLATES = {
          "pr_comment" => Workflows::PrFeedback,
          "external_pr_feedback" => Workflows::ExternalPrFeedback
        }.freeze
        private_constant :RETRY_TEMPLATES

        def retry_feedback_handling(job, comment)
          original = comment.handling_workflow
          template = RETRY_TEMPLATES[original&.trigger_kind]
          if template
            artifacts = original.artifacts.to_h.deep_dup
            artifacts["pr_feedback_iteration"] = job.workflows.where(trigger_kind: Workflow::TriggerKind.feedback_values).count + 1
            artifacts["pr_review_comment_ids"] = Array(artifacts["pr_review_comment_ids"]).map(&:to_i).presence || [ comment.id ]
            workflow = template.instantiate(job: job, artifacts: artifacts)
            StepDispatcher.start_workflow(workflow)
            ChatFeedbackSubmission::Result.new(workflow: workflow, error: nil)
          else
            artifacts = original&.artifacts.to_h
            source = artifacts["feedback_source"].to_h.presence || feedback_source_artifacts(comment, "retry")["feedback_source"]
            source = source.merge("action" => "retry", "confirmed_by" => "operator")
            ChatFeedbackSubmission.call(
              job: job,
              feedback: artifacts["chat_feedback"].presence || comment.body.to_s,
              allowed_states: %w[implemented failed],
              extra_artifacts: { "feedback_source" => source }
            )
          end
        end
      end
    end
  end
end
