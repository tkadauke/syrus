module Api
  module V1
    module App
      class DiffReviewCommentsController < BaseController
        def index
          job = find_job
          render json: comments_payload(job, filtered_comments(job))
        end

        def create
          job = find_job
          return unless authorize_job_mutation!(job)

          comment = job.diff_review_comments.build(comment_params.merge(user: Current.user))
          if comment.save
            render json: comments_payload(job, job.diff_review_comments.where(id: comment.id)), status: :created
          else
            render_error("validation_failed", comment.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def update
          job = find_job
          return unless authorize_job_mutation!(job)

          comment = job.diff_review_comments.find(params[:id])
          if comment.update(comment_params)
            render json: comments_payload(job, job.diff_review_comments.where(id: comment.id))
          else
            render_error("validation_failed", comment.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def resolve
          job = find_job
          return unless authorize_job_mutation!(job)

          comment = job.diff_review_comments.find(params[:id])
          comment.resolve!
          render json: comments_payload(job, job.diff_review_comments.where(id: comment.id))
        end

        private

        def find_job
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end

        def filtered_comments(job)
          job.diff_review_comments
             .includes(:user, :workflow, :run)
             .for_surface(params[:surface])
             .for_path(params[:path])
             .for_state(params[:state])
             .for_base_ref(params[:base_ref])
             .for_head_ref(params[:head_ref])
             .ordered
        end

        def comment_params
          params.require(:diff_review_comment).permit(
            :surface,
            :base_ref,
            :head_ref,
            :path,
            :side,
            :old_line,
            :new_line,
            :diff_hunk,
            :body,
            :state,
            :workflow_id,
            :run_id,
            context: {}
          )
        end

        def comments_payload(job, comments)
          ::App::DiffReviewCommentsPayload.build(job: job, comments: comments)
        end
      end
    end
  end
end
