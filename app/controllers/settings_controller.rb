class SettingsController < ApplicationController
  before_action :require_admin

  def edit
    @setting = AppSetting.current
  end

  def update
    @setting = AppSetting.current
    if @setting.update(settings_params)
      redirect_to edit_settings_path, notice: "Settings updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def settings_params
    params.expect(app_setting: [ :signups_open ])
  end
end
