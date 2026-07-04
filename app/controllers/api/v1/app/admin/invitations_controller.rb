module Api
  module V1
    module App
      module Admin
        class InvitationsController < BaseController
          def index
            render json: invitations_payload
          end

          def create
            invitation = Invitation.new(invitation_params.merge(invited_by: Current.user))

            if invitation.save
              InvitationMailer.invite(invitation).deliver_later

              render json: invitations_payload.merge(message: I18n.t("api.admin_invitations.created", email: invitation.email_address)),
                     status: :created
            else
              render_error("validation_failed", invitation.errors.full_messages.to_sentence,
                           status: :unprocessable_content)
            end
          end

          def destroy
            invitation = Invitation.find(params[:id])
            invitation.destroy!

            render json: invitations_payload.merge(message: I18n.t("api.admin_invitations.revoked"))
          end

          private

          def invitations_payload
            {
              invitations: Invitation.pending.order(created_at: :desc).map { |invitation| invitation_json(invitation) }
            }
          end

          def invitation_json(invitation)
            {
              id: invitation.id,
              email_address: invitation.email_address,
              token: invitation.token,
              share_url: new_user_url(token: invitation.token),
              expires_at: invitation.expires_at.iso8601,
              created_at: invitation.created_at.iso8601,
              invited_by_email_address: invitation.invited_by.email_address
            }
          end

          def invitation_params
            params.expect(invitation: [ :email_address ])
          end
        end
      end
    end
  end
end
