class ApplicationMailer < ActionMailer::Base
  default from: -> { ApplicationMailer.default_from_address }
  layout "mailer"
  around_action :render_in_recipient_locale

  def self.default_from_address
    ENV.fetch("SYRUS_MAILER_FROM") do
      "Syrus <noreply@#{ENV.fetch("SYRUS_APP_HOST", "localhost")}>"
    end
  end

  private

  def render_in_recipient_locale(&)
    I18n.with_locale(mail_locale, &)
  end

  def mail_locale
    requested_locale = params[:locale].to_s
    supported_locales = User::LOCALES & I18n.available_locales.map(&:to_s)
    return requested_locale if supported_locales.include?(requested_locale)

    default_locale = I18n.default_locale.to_s
    supported_locales.include?(default_locale) ? default_locale : supported_locales.first
  end
end
