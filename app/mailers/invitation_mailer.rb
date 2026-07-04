class InvitationMailer < ApplicationMailer
  def invite(invitation)
    @invitation = invitation
    @inviter = invitation.invited_by

    mail to: invitation.email_address
  end
end
