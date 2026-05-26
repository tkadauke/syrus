class SettingsController < ApplicationController
  before_action :require_admin

  def edit
    @setting = AppSetting.current
  end

  def update
    @setting = AppSetting.current
    if params[:clear_secret].present?
      clear_secret(params[:clear_secret])
      return
    end

    attrs = settings_params.to_h.reject { |_, v| v.blank? }
    if @setting.update(attrs)
      redirect_to edit_settings_path, notice: "Settings updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

  def clear_secret(secret)
    label = AppSetting::CLEARABLE_SECRETS[secret.to_s]
    redirect_to edit_settings_path, alert: "Unknown secret." and return unless label

    @setting.clear_secret!(secret)
    redirect_to edit_settings_path, notice: "#{label} cleared."
  end

  def settings_params
    params.expect(app_setting: [ :signups_open, :telegram_bot_token, :telegram_webhook_secret ])
  end
end
