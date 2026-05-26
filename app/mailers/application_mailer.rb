class ApplicationMailer < ActionMailer::Base
  default from: -> { ApplicationMailer.default_from_address }
  layout "mailer"

  def self.default_from_address
    ENV.fetch("SYRUS_MAILER_FROM") do
      "Syrus <noreply@#{ENV.fetch("SYRUS_APP_HOST", "localhost")}>"
    end
  end
end
