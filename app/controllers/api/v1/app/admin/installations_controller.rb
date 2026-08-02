module Api
  module V1
    module App
      module Admin
        class InstallationsController < BaseController
          def index
            render json: ::Admin::Installations::Payload.new.show
          end

          def diagnostic
            render json: GithubAppInstallationDiagnostic.new(slug: params[:repository]).show
          end

          def refresh
            SyncInstallationsJob.perform_later(Current.user.id)
            render json: ::Admin::Installations::Payload.new.show.merge(ok: true, message: "Installation sync queued.")
          end
        end
      end
    end
  end
end
