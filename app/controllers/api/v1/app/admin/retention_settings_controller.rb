module Api
  module V1
    module App
      module Admin
        # Generic reader/writer over RetentionPolicyRegistry: every row on the
        # admin Retention Settings page comes from iterating the registry
        # (plus the cached RetentionSizeSnapshotJob sizing data and current
        # AppSetting values), never a hand-listed table set here.
        class RetentionSettingsController < BaseController
          def show
            render json: payload
          end

          def update
            setting = AppSetting.current
            if setting.update(update_params)
              render json: payload.merge(message: I18n.t("api.admin_retention_settings.updated"))
            else
              render_error("validation_failed", setting.errors.full_messages.to_sentence,
                           status: :unprocessable_content)
            end
          end

          private

          def payload
            setting = AppSetting.current
            {
              tables: RetentionPolicyRegistry.definitions.map { |definition| table_payload(definition, setting) },
              available_space: RetentionSizeSnapshotJob.available_space&.as_json,
              retention_available_space_override_gb: setting.retention_available_space_override_gb
            }
          end

          def table_payload(definition, setting)
            snapshot = RetentionSizeSnapshotJob.table_snapshot(definition.key)
            {
              key: definition.key,
              table_name: definition.table_name,
              description: definition.description,
              category: definition.category,
              setting_key: definition.setting_key,
              unit: definition.unit,
              default_value: definition.default_value,
              retention_value: setting.public_send(definition.setting_key),
              row_count_estimate: snapshot&.row_count_estimate,
              byte_size_estimate: snapshot&.byte_size_estimate,
              estimated_max_byte_size: snapshot&.estimated_max_byte_size,
              computed_at: snapshot&.computed_at&.iso8601,
              archivable: definition.archivable,
              archive_setting_key: definition.archivable ? definition.archive_setting_key : nil,
              archive_before_delete: definition.archivable ? setting.public_send(definition.archive_setting_key) : false
            }
          end

          def update_params
            permitted_settings = (RetentionPolicyRegistry.definitions.map(&:setting_key) +
                                 RetentionPolicyRegistry.archive_app_setting_definitions.map(&:key) +
                                 [ :retention_available_space_override_gb ]).uniq

            params
              .expect(retention_settings: permitted_settings)
              .to_h
              .reject { |_key, value| value.nil? || value == "" }
          end
        end
      end
    end
  end
end
