module Api
  module V1
    module Admin
      class RepositoriesController < BaseController
        def index
          repositories = Repository.includes(:jobs).order(:owner, :name)
          render json: {
            count: repositories.size,
            repositories: repositories.map { |repository| serialize(repository) }
          }
        end

        private

        def serialize(repository)
          last_job = repository.jobs.order(updated_at: :desc).first
          {
            id: repository.id,
            slug: repository.slug,
            active_jobs: repository.jobs.open_threads.count,
            last_job: last_job && {
              id: last_job.id,
              state: last_job.state,
              title: last_job.issue_title,
              updated_at: last_job.updated_at
            }
          }
        end
      end
    end
  end
end
