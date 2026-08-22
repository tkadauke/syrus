module Api
  module V1
    module App
      module Admin
        # Admin surface for the shared sccache compiler-cache bucket
        # (EPIC-251): footprint stats, plus a confirm-before-destructive-
        # action flow for clearing it (full or scoped by age). Clearing
        # never fires directly off `create` — it creates a `pending`
        # AdminBuildCacheClearRequest with a required audit reason, and a
        # separate `confirm` call actually mutates the bucket. See
        # AdminBuildCacheClearRequest.
        class BuildCacheController < BaseController
          def show
            render json: payload.show
          end

          def create_clear_request
            request = AdminBuildCacheClearRequest.new(clear_request_params.merge(user: Current.user))
            if request.save
              render json: payload.show, status: :created
            else
              render_error("validation_failed", request.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          end

          def confirm_clear_request
            request = AdminBuildCacheClearRequest.find(params[:id])
            if request.confirm!(user: Current.user)
              render json: payload.show
            else
              render_error("cannot_confirm", "Request is no longer pending, or the build cache bucket is not configured.",
                           status: :unprocessable_content)
            end
          end

          def cancel_clear_request
            request = AdminBuildCacheClearRequest.find(params[:id])
            if request.cancel!
              render json: payload.show
            else
              render_error("cannot_cancel", "Request is no longer pending.", status: :unprocessable_content)
            end
          end

          private

          def payload
            ::Admin::BuildCache::Payload.new
          end

          def clear_request_params
            params.expect(admin_build_cache_clear_request: %i[ scope older_than_days reason ])
          end
        end
      end
    end
  end
end
