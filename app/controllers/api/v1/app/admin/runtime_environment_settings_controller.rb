module Api
  module V1
    module App
      module Admin
        class RuntimeEnvironmentSettingsController < BaseController
          REGISTRY_FIELDS = %i[url repository_prefix builder_username builder_password worker_username worker_password admin_username admin_password].freeze

          def show
            render json: payload
          end

          def update
            attributes = update_params
            setting = AppSetting.current
            setting.assign_attributes(attributes.except(:runtime_environment_policy))
            setting.runtime_environment_policy = attributes[:runtime_environment_policy] if attributes.key?(:runtime_environment_policy)
            setting.save!
            AdminAction.log!(user: current_user, action: "runtime_environment_settings.update", params: audit_metadata(attributes))
            render json: payload.merge(message: I18n.t("api.admin_runtime_environment_settings.updated"))
          rescue ActiveRecord::RecordInvalid, RuntimeImages::EnvironmentPolicy::Invalid => error
            render_error("validation_failed", error.message, status: :unprocessable_content)
          end

          private

          def payload
            setting = AppSetting.current
            {
              registry: {
                url: attribute(setting, :runtime_image_registry_url).presence || ENV["SYRUS_RUNTIME_IMAGE_REGISTRY_URL"].to_s,
                repository_prefix: attribute(setting, :runtime_image_registry_repository_prefix).presence || ENV.fetch("SYRUS_RUNTIME_IMAGE_REGISTRY_REPOSITORY_PREFIX", "syrus"),
                credentials: %i[builder worker admin].to_h { |role| [ role, credential_payload(setting, role) ] }
              },
              policy: RuntimeImages::EnvironmentPolicy.current.to_h,
              network_rules: RuntimeImageBuildNetworkRule.order(:source_class, :host, :port).map { |rule| rule.slice(*%w[id source_class host port path_prefix ecosystem required enabled note]) },
              source_classes: RuntimeImages::BuildNetwork::SourceClass.registry.keys,
              language_ecosystems: RuntimeImages::BuildNetwork::SourceClass::LanguageRegistry::ECOSYSTEMS
            }
          end

          def update_params
            submitted = params.expect(runtime_environment_settings: [ { registry: REGISTRY_FIELDS, policy: {} } ]).to_h
            registry = submitted.fetch("registry", {}).each_with_object({}) do |(key, value), result|
              column = :"runtime_image_registry_#{key}"
              result[column] = value if AppSetting.column_names.include?(column.to_s) && !(key.end_with?("password") && value.blank?)
            end
            policy = submitted["policy"]
            registry[:runtime_environment_policy] = RuntimeImages::EnvironmentPolicy.new(
              RuntimeImages::EnvironmentPolicy.defaults.deep_merge(policy.to_h.deep_stringify_keys)
            ).to_h if policy
            registry
          end

          def attribute(setting, name)
            setting.has_attribute?(name) ? setting.public_send(name) : nil
          end

          def credential_payload(setting, role)
            username = attribute(setting, :"runtime_image_registry_#{role}_username").presence || ENV["SYRUS_RUNTIME_IMAGE_REGISTRY_#{role.to_s.upcase}_USERNAME"].to_s
            password = attribute(setting, :"runtime_image_registry_#{role}_password").presence || ENV["SYRUS_RUNTIME_IMAGE_REGISTRY_#{role.to_s.upcase}_PASSWORD"].to_s
            { username: username, password_set: password.present? }
          end

          def audit_metadata(attributes)
            { fields: attributes.keys.map(&:to_s).sort, policy_digest: RuntimeImages::Verifications::Policy.digest }
          end
        end
      end
    end
  end
end
