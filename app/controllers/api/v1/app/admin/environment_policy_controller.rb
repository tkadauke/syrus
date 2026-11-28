module Api
  module V1
    module App
      module Admin
        class EnvironmentPolicyController < BaseController
          def show
            render json: payload
          end

          def update
            policy = CoworkerEnvironmentPolicy.validate!(params.expect(environment_policy: {}).to_unsafe_h)
            setting = AppSetting.current
            before = CoworkerEnvironmentPolicy.current
            setting.update!(coworker_environment_policy: policy)
            AdminAction.log!(user: Current.user, action: :update_coworker_environment_policy,
                             params: { before: before, after: policy })
            render json: payload.merge(message: I18n.t("api.admin_environment_policy.updated"))
          rescue ArgumentError, ActiveRecord::RecordInvalid => error
            render_error("validation_failed", error.message, status: :unprocessable_content)
          end

          private

          def payload
            registry = RuntimeImages::OciRegistry::Configuration.from_env
            {
              policy: CoworkerEnvironmentPolicy.current,
              registry: registry ? { configured: true, url: registry.url, repository_prefix: registry.repository_prefix,
                                      secure: registry.secure?, roles: RuntimeImages::OciRegistry::Configuration::ROLES.index_with { |role| registry.credential?(role) } } : { configured: false },
              network_rules_path: "/api/v1/admin/runtime_image_build_network_rules"
            }
          rescue RuntimeImages::Error => error
            { policy: CoworkerEnvironmentPolicy.current, registry: { configured: false, error: error.message },
              network_rules_path: "/api/v1/admin/runtime_image_build_network_rules" }
          end
        end
      end
    end
  end
end
