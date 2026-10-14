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
            admission_control_changed = update_params.key?("workflow_admission_control_enabled") &&
              ActiveModel::Type::Boolean.new.cast(update_params["workflow_admission_control_enabled"]) != setting.workflow_admission_control_enabled
            if admission_control_changed
              update_params["workflow_admission_control_changed_at"] = Time.current
              update_params["workflow_admission_control_changed_by_user_id"] = Current.user.id
            end

            if setting.update(update_params)
              audit_workflow_admission_control_change!(setting) if admission_control_changed
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
              settings: AppSettingRegistry.non_secret_admin_settings_keys.index_with { |key| setting.public_send(key) }.merge(
                workflow_admission_control_changed_at: setting.workflow_admission_control_changed_at&.iso8601,
                workflow_admission_control_changed_by: setting.workflow_admission_control_changed_by_user&.then { |user|
                  {
                    id: user.id,
                    email_address: user.email_address,
                    display_name: user.display_name
                  }
                },
                metadata: AppSettingRegistry.metadata_for(AppSettingRegistry.admin_settings_keys),
                clearable_secrets: AppSetting.clearable_secrets.map do |key, label|
                  {
                    key: key,
                    label: label,
                    set: setting.public_send(key).present?
                  }
                end
              )
            }
          end

          def settings_params
            permitted_settings = AppSettingRegistry.admin_settings_keys +
                                 AppSetting.clearable_secrets.keys.map(&:to_sym)

            params
              .expect(app_setting: permitted_settings)
              .to_h
              .each_with_object({}) do |(key, value), settings|
                definition = AppSettingRegistry.fetch(key)
                next if value.blank? && !definition.boolean? && (definition.secret || definition.type != :string)

                settings[key] = nullable_string?(key) && value.blank? ? nil : value
              end
          end

          def nullable_string?(key)
            definition = AppSettingRegistry.fetch(key)
            definition.type == :string && AppSetting.columns_hash.fetch(key.to_s).null
          end

          def audit_workflow_admission_control_change!(setting)
            enabled = setting.workflow_admission_control_enabled
            AdminAction.log!(
              user: Current.user,
              action: enabled ? :enable_workflow_admission_control : :disable_workflow_admission_control,
              params: { source: "app_admin_settings" }
            )
            Rails.logger.warn(
              "[AdminSettings] workflow admission control #{enabled ? "enabled" : "disabled"} " \
              "by user_id=#{Current.user.id}"
            )
            WorkflowAdmissionControlWakeup.call
          end
        end
      end
    end
  end
end
