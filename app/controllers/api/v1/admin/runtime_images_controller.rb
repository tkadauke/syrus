module Api
  module V1
    module Admin
      # Diagnostics for the Runtime Image Service. Reads durable records only.
      #
      #   GET  /api/v1/admin/runtime_images           - health checks, image counts, retained
      #                                                 rollback images, failed cleanup, cache
      #                                                 footprint, pull outcomes, recent audit
      #   POST /api/v1/admin/runtime_images/reconcile - queue a reconciliation pass
      class RuntimeImagesController < BaseController
        def show
          render json: RuntimeImages::Health.new.snapshot
        end

        def reconcile
          RuntimeImageReconcileJob.perform_later
          head :accepted
        end
      end
    end
  end
end
