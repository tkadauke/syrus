module Api
  module V1
    module App
      class ChatJobStatusController < BaseController
        def show
          chat_session = Current.user.accessible_chat_sessions.find(params[:chat_id])
          payload = ChatJobStatusQuery.call(chat_session)
          fresh_when etag: Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(payload)), public: false
          render json: payload unless performed?
        end
      end
    end
  end
end
