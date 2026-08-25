module Api
  module V1
    module App
      class ChatParticipantsController < BaseController
        def create
          chat_session = find_chat_session
          unless chat_session.group?
            render_error("not_found", "Chat not found.", status: :not_found)
            return
          end

          target_user = target_user_from_params
          unless target_user
            render_error("validation_failed", "Unknown user id.", status: :unprocessable_content)
            return
          end

          if chat_session.chat_participants.exists?(user_id: target_user.id)
            render_error("validation_failed", "That user is already a participant.", status: :unprocessable_content)
            return
          end

          chat_session.chat_participants.create!(user: target_user, role: "member")
          chat_session.broadcast_participants_update!

          render json: { participants: chat_session.participants_payload }, status: :created
        end

        def destroy
          chat_session = find_chat_session
          unless chat_session.group?
            render_error("not_found", "Chat not found.", status: :not_found)
            return
          end

          target_participant = chat_session.chat_participants.find_by(user_id: params[:user_id])
          unless target_participant
            render_error("validation_failed", "That user is not a participant.", status: :unprocessable_content)
            return
          end

          if chat_session.chat_participants.count <= 1
            render_error("validation_failed", "A group chat must keep at least one participant.", status: :unprocessable_content)
            return
          end

          # Notify the removed participant's own client too, so its open
          # session updates live — by the time broadcast fires, `participants`
          # no longer includes them.
          recipients = chat_session.participants.to_a
          target_participant.destroy!
          chat_session.broadcast_participants_update!(recipients: recipients)

          render json: { participants: chat_session.participants_payload }
        end

        private

        def find_chat_session
          Current.user.accessible_chat_sessions.active.find(params[:chat_id])
        end

        def target_user_from_params
          id = Integer(params[:user_id], exception: false)
          User.find_by(id: id) if id
        end
      end
    end
  end
end
