module Api
  module V1
    module App
      module Admin
        class JobMetadataController < Api::V1::App::JobMetadataController
          before_action :require_admin

          def override_dependencies
            job = find_job
            job.force_run_dependencies!(user: Current.user)
            render_metadata(job.reload, message: "Dependency gate overridden.", changed: [ "dependencies" ])
          end

          private

          def find_job
            find_job_by_ref(Job.includes(:repository, :tags, dependencies: [ :created_by_user, :depends_on_epic, depends_on_job: :repository ]), params[:job_id])
          end
        end
      end
    end
  end
end
