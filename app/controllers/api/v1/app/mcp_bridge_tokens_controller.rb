module Api
  module V1
    module App
      # Issues, lists and revokes the signed-in user's MCP bridge tokens
      # (see McpBridgeToken). A token's plaintext appears only in the
      # create response.
      class McpBridgeTokensController < BaseController
        def index
          tokens = Current.user.mcp_bridge_tokens.order(created_at: :desc)
          render json: { tokens: tokens.map(&:as_payload) }
        end

        def create
          name = params[:name].to_s.strip
          return render_error("invalid_name", I18n.t("mcp_bridge.name_required"), status: :unprocessable_content) if name.blank?

          token, plaintext = McpBridgeToken.issue!(user: Current.user, name: name.first(100))
          render json: { token: token.as_payload, plaintext: plaintext, endpoint: "#{request.base_url}#{McpBridge::Endpoint::PATH}" },
            status: :created
        end

        def destroy
          token = Current.user.mcp_bridge_tokens.find(params[:id])
          token.revoke!
          render json: { token: token.as_payload }
        end
      end
    end
  end
end
