module Api
  module V1
    module App
      module Admin
        # Generic reader/writer over RetentionPolicyRegistry: every row on the
        # admin Retention Settings page comes from iterating the registry
        # (plus the cached RetentionSizeSnapshotJob sizing data and current
        # AppSetting values), never a hand-listed table set here.
        class RetentionSettingsController < BaseController
          INFINITE_FLAG_SUFFIX = "_infinite".freeze

          def show
            render json: payload
          end

          def update
            attributes = update_params
            return if performed?

            setting = AppSetting.current
            if setting.update(attributes)
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
              retention_available_space_override_gb: setting.retention_available_space_override_gb,
              storage_limits: {
                prepared_layer_cache_default_bytes: setting.prepared_layer_cache_gb.gigabytes,
                coding_workspace_bytes: AppSetting.chat_coding_workspace_budget_bytes,
                prepared_layer_cache_workers: prepared_layer_cache_workers
              }
            }
          end

          def prepared_layer_cache_workers
            WorkerHostHealthSample.worker_role
              .where("observed_at >= ?", ::Admin::WorkerHealthPayload::CURRENT_SAMPLE_WINDOW.ago)
              .recent
              .limit(500)
              .to_a
              .uniq { |sample| sample.worker_storage_key.presence || sample.hostname }
              .filter_map do |sample|
                bytes = sample.raw_metrics&.fetch("prepared_layer_cache_budget_bytes", nil)
                source = sample.raw_metrics&.fetch("prepared_layer_cache_budget_source", nil)
                next if bytes.nil? || !source.in?(%w[app_setting worker_environment])

                {
                  hostname: sample.hostname,
                  worker_storage_key: sample.worker_storage_key,
                  budget_bytes: bytes,
                  source: source,
                  observed_at: sample.observed_at&.iso8601
                }
              end
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
            definitions = RetentionPolicyRegistry.definitions
            infinite_flag_keys = definitions.map { |definition| infinite_flag_key(definition) }
            permitted_settings = (definitions.map(&:setting_key) +
                                 infinite_flag_keys +
                                 RetentionPolicyRegistry.archive_app_setting_definitions.map(&:key) +
                                 [ :retention_available_space_override_gb ]).uniq

            submitted = params
              .expect(retention_settings: permitted_settings)
              .to_h

            validation_message = validate_retention_values(submitted, definitions)
            if validation_message
              render_error("validation_failed", validation_message, status: :unprocessable_content)
              return
            end

            submitted
              .except(*infinite_flag_keys.map(&:to_s))
              .reject { |_key, value| value.nil? || value == "" }
          end

          def validate_retention_values(submitted, definitions)
            definitions.each do |definition|
              setting_key = definition.setting_key.to_s
              next unless submitted.key?(setting_key)

              value = submitted[setting_key]
              return I18n.t("api.admin_retention_settings.retention_value_required", table: definition.table_name) if value.nil? || value == ""

              numeric_value = Integer(value, exception: false)
              return I18n.t("api.admin_retention_settings.retention_value_required", table: definition.table_name) if numeric_value.nil?

              infinite_requested = ActiveModel::Type::Boolean.new.cast(submitted[infinite_flag_key(definition).to_s])
              if numeric_value.zero? && !infinite_requested
                return I18n.t("api.admin_retention_settings.infinite_flag_required", table: definition.table_name)
              end

              if !numeric_value.zero? && infinite_requested
                return I18n.t("api.admin_retention_settings.infinite_value_required", table: definition.table_name)
              end
            end

            nil
          end

          def infinite_flag_key(definition)
            :"#{definition.setting_key}#{INFINITE_FLAG_SUFFIX}"
          end
        end
      end
    end
  end
end
