class SystemAlertMailer < ApplicationMailer
  def alarm(alert_payload, to:)
    @alert = alert_payload
    mail to: to, subject: t(".subject", title: @alert.fetch(:title))
  end
end
