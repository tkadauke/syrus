module Api
  module V1
    module App
      class DiffReviewCommentsController < BaseController
        def index
          job = find_job
          version = selected_version(job)
          render json: comments_payload(job, filtered_comments(job, version), version: version)
        end

        def create
          job = find_job
          return unless authorize_job_mutation!(job)

          version = selected_version(job)
          unless version
            render_error("validation_failed", "Diff review version is required.", status: :unprocessable_content)
            return
          end

          comment = job.diff_review_comments.build(comment_params.except(:diff_review_version_id).merge(
            user: Current.user,
            diff_review_version: version,
            base_ref: comment_params[:base_ref].presence || version.base_sha,
            head_ref: comment_params[:head_ref].presence || version.head_sha
          ))
          if comment.save
            render json: comments_payload(job, job.diff_review_comments.where(id: comment.id), version: version), status: :created
          else
            render_error("validation_failed", comment.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def update
          job = find_job
          return unless authorize_job_mutation!(job)

          comment = find_versioned_comment(job)
          if comment.update(comment_params.except(:diff_review_version_id))
            render json: comments_payload(job, job.diff_review_comments.where(id: comment.id), version: comment.diff_review_version)
          else
            render_error("validation_failed", comment.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def destroy
          job = find_job
          return unless authorize_job_mutation!(job)

          comment = find_versioned_comment(job)
          unless comment.state == "draft"
            render_error("validation_failed", "Only draft comments can be deleted.", status: :unprocessable_content)
            return
          end

          comment.destroy!
          render json: { job_id: job.id, deleted_id: comment.id }
        end

        def resolve
          job = find_job
          return unless authorize_job_mutation!(job)

          comment = find_versioned_comment(job)
          comment.resolve!
          render json: comments_payload(job, job.diff_review_comments.where(id: comment.id), version: comment.diff_review_version)
        end

        def reply
          job = find_job
          return unless authorize_job_mutation!(job)

          parent = find_versioned_comment(job)
          reply = parent.build_reply(user: Current.user, body: params[:body])
          if reply.save
            render json: comments_payload(job, job.diff_review_comments.where(id: reply.id), version: parent.diff_review_version), status: :created
          else
            render_error("validation_failed", reply.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def submit
          job = find_job
          return unless authorize_job_mutation!(job)

          result = DiffReviewCommentFeedbackSubmission.call(
            job: job,
            comment_ids: params[:comment_ids],
            diff_review_version: selected_version(job),
            actor: Current.user
          )

          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render json: {
            message: "Diff comments submitted as chat feedback.",
            workflow: {
              id: result.workflow.id,
              trigger_kind: result.workflow.trigger_kind,
              state: result.workflow.state
            },
            comments: comments_payload(job, result.comments, version: nil)[:comments]
          }, status: :created
        end

        private

        def find_job
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end

        def filtered_comments(job, version)
          return all_version_comments(job) if ActiveModel::Type::Boolean.new.cast(params[:all_versions])
          return DiffReviewComment.none unless version

          job.diff_review_comments
             .includes(:user, :workflow, :run, :diff_review_version)
             .for_diff_review_version(version.id)
             .for_surface(params[:surface])
             .for_path(params[:path])
             .for_state(params[:state])
             .for_base_ref(params[:base_ref])
             .for_head_ref(params[:head_ref])
             .for_workflow(params[:workflow_id])
             .for_run(params[:run_id])
             .ordered
        end

        def all_version_comments(job)
          job.diff_review_comments
             .includes(:user, :workflow, :run, :diff_review_version)
             .for_surface(params[:surface])
             .for_path(params[:path])
             .for_state(params[:state])
             .for_workflow(params[:workflow_id])
             .for_run(params[:run_id])
             .ordered
        end

        def find_versioned_comment(job)
          version = selected_version(job)
          raise ActiveRecord::RecordNotFound unless version

          job.diff_review_comments.for_diff_review_version(version.id).find(params[:id])
        end

        def comment_params
          params.require(:diff_review_comment).permit(
            :surface,
            :diff_review_version_id,
            :base_ref,
            :head_ref,
            :anchor_kind,
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

        def comments_payload(job, comments, version:)
          ::App::DiffReviewCommentsPayload.build(job: job, comments: comments, version: version)
        end

        def selected_version(job)
          version_id = params[:diff_review_version_id].presence ||
            params[:version_id].presence ||
            params.dig(:diff_review_comment, :diff_review_version_id).presence
          return job.diff_review_versions.find(version_id) if version_id.present?

          job.diff_review_versions.latest_first.first
        end
      end
    end
  end
end
