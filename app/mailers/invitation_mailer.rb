class InvitationMailer < ApplicationMailer
  def invite(invitation)
    @invitation = invitation
    @inviter = invitation.invited_by

    mail subject: "You're invited to Syrus", to: invitation.email_address
  end
end
