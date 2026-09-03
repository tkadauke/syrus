module Api
  module V1
    module App
      class RepositoryRecommendationsController < RepositoriesController
        def create
          repository = Repository.accessible_to(Current.user).active.find(params[:repository_id])
          action_id = params[:recommendation_id].to_s
          recommendation = applicable_recommendation(repository, action_id)
          unless recommendation
            render_error("validation_failed", "That recommendation is no longer applicable.", status: :unprocessable_content)
            return
          end

          cta = recommendation.fetch(:cta)
          if cta.fetch(:kind) == "job"
            return unless authorize_recommendation_job!(repository)

            create_recommendation_job(repository, action_id)
          elsif cta.fetch(:kind) == "toggle"
            return unless authorize_recommendation_toggle!(repository)

            apply_recommendation_toggle(repository, action_id)
          else
            render_error("validation_failed", "That recommendation does not have an API action.", status: :unprocessable_content)
          end
        end

        private

        def applicable_recommendation(repository, action_id)
          ::App::RepositoryFeatureRecommendations
            .for(repository: repository, user: Current.user)
            .find { |entry| entry.dig(:cta, :action_id) == action_id }
        end

        def authorize_recommendation_job!(repository)
          return true if RepositoryPolicy.new(Current.user, repository).write?

          render_error("forbidden", "Only a repository member with write access or an admin can create recommendation jobs.", status: :forbidden)
          false
        end

        def authorize_recommendation_toggle!(repository)
          return true if RepositoryPolicy.new(Current.user, repository).update?

          render_error("forbidden", "Only a repository admin can update recommendation settings.", status: :forbidden)
          false
        end

        def create_recommendation_job(repository, action_id)
          action = ::App::RepositoryFeatureRecommendations.job_action(action_id)
          unless action
            render_error("validation_failed", "That recommendation cannot create a job.", status: :unprocessable_content)
            return
          end

          job = Current.user.jobs.create!(
            repository: repository,
            kind: "direct",
            issue_number: nil,
            issue_title: action.fetch(:title),
            title_pending: false,
            issue_body: action.fetch(:prompt),
            agent_provider: repository.effective_agent_provider(user: Current.user),
            job_provider_setting: "default",
            priority: "medium",
            state: Job.initial_state_for_creator(Current.user)
          )
          job.advance_after_triage! if job.may_advance_after_triage?

          render json: {
            message: "Recommendation job created.",
            redirect_to: job_path(job),
            job: {
              id: job.id,
              slug: job.slug,
              state: job.state,
              issue_title: job.issue_title,
              job_path: job_path(job)
            }
          }, status: :created
        end

        def apply_recommendation_toggle(repository, action_id)
          attrs = ::App::RepositoryFeatureRecommendations.toggle_attributes(action_id)
          unless attrs
            render_error("validation_failed", "That recommendation cannot update repository settings.", status: :unprocessable_content)
            return
          end

          if repository.update(attrs)
            render json: repository_detail_payload(repository.reload, page: detail_page, message: "Repository setting enabled.")
          else
            render_error("validation_failed", repository.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def detail_page
          [ params.fetch(:page, 1).to_i, 1 ].max
        end
      end
    end
  end
end
