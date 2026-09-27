class SystemAlertMailer < ApplicationMailer
  def alarm(alert_payload, to:)
    @alert = alert_payload
    mail to: to, subject: "[Syrus alarm] #{@alert.fetch(:title)}"
  end
end
