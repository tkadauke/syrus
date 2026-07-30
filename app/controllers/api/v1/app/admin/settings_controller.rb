module Api
  module V1
    module App
      module Admin
        class SettingsController < BaseController
          def show
            render json: settings_payload
          end

          def update
            setting = AppSetting.current
            update_params = settings_params
            update_params["mode_configured_at"] = Time.current if update_params.key?("mode") && setting.mode_configured_at.nil?

            if setting.update(update_params)
              render json: settings_payload.merge(message: I18n.t("api.admin_settings.updated"))
            else
              render_error("validation_failed", setting.errors.full_messages.to_sentence,
                           status: :unprocessable_content)
            end
          end

          def clear_secret
            label = AppSetting.clearable_secrets[params[:secret].to_s]
            return render_error("unknown_secret", I18n.t("api.admin_settings.unknown_secret"), status: :unprocessable_content) unless label

            AppSetting.current.clear_secret!(params[:secret])
            render json: settings_payload.merge(message: I18n.t("api.admin_settings.secret_cleared", label: label))
          end

          private

          def settings_payload
            setting = AppSetting.current
            {
              settings: {
                signups_open: setting.signups_open,
                # Walkthrough-video media management — analysis + screenshots
                # always persist; these bound only the stored video blobs.
                video_retention_days: setting.video_retention_days,
                video_storage_budget_mb: setting.video_storage_budget_mb,
                # Global cap on concurrent agent Runs across all worker pods.
                # 0 = unlimited (bounded only by per-pod JOB_CONCURRENCY).
                max_concurrent_agent_runs: setting.max_concurrent_agent_runs,
                proactive_rebase_commit_threshold: setting.proactive_rebase_commit_threshold,
                mode: setting.mode,
                clearable_secrets: AppSetting.clearable_secrets.map do |key, label|
                  {
                    key: key,
                    label: label,
                    set: setting.public_send(key).present?
                  }
                end
              }
            }
          end

          def settings_params
            permitted_settings = [ :signups_open, :video_retention_days, :video_storage_budget_mb, :max_concurrent_agent_runs, :proactive_rebase_commit_threshold, :mode ] +
                                 AppSetting.clearable_secrets.keys.map(&:to_sym)

            params
              .expect(app_setting: permitted_settings)
              .to_h
              .reject { |key, value| booleanish?(key) ? false : value.blank? }
          end

          # signups_open is a boolean (false must survive the blank-reject);
          # everything else is only applied when a value is actually sent.
          def booleanish?(key)
            key == "signups_open"
          end
        end
      end
    end
  end
end
