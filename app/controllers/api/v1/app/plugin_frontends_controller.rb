module Api
  module V1
    module App
      class PluginFrontendsController < BaseController
        # Native ESM imports are script requests rather than XHR, so Rails'
        # legacy non-XHR JavaScript response check would reject the same-origin
        # import. The route remains authenticated and serves only declared files.
        skip_forgery_protection only: :show

        def show
          asset = PluginFrontendAssets.find(params[:plugin_name], params[:kind])
          return head :not_found unless asset && ActiveSupport::SecurityUtils.secure_compare(params[:v].to_s, asset.hash.to_s)

          response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
          send_file asset.path, type: asset.content_type, disposition: "inline"
        end
      end
    end
  end
end
