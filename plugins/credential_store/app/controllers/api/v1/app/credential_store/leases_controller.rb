module Api
  module V1
    module App
      module CredentialStore
        class LeasesController < BaseController
          before_action :require_credential_store_enabled

          def create
            context = current_invocation_context
            unless context
              render_error("forbidden", "Credential leases require Syrus runtime CLI authentication.", status: :forbidden)
              return
            end

            metadata = ::CredentialStore::Broker.with_credential_env(
              context: context,
              credential: lease_attrs.fetch(:credential),
              type: lease_attrs.fetch(:type),
              env_key: "SYRUS_CREDENTIAL_LEASE_PROBE",
              purpose: lease_attrs.fetch(:purpose),
              tool_name: lease_attrs[:tool_name],
              target: lease_attrs[:target],
              expires_in: expires_in
            ) { |_env, lease_metadata| lease_metadata }

            render json: { lease: metadata }
          rescue ::CredentialStore::Broker::NotFound => e
            render_error("not_found", e.message, status: :not_found)
          rescue ::CredentialStore::Broker::Denied => e
            render_error("forbidden", e.message, status: :forbidden)
          end

          private

          def require_credential_store_enabled
            return if ::CredentialStore.enabled?

            render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: "credential_store"), status: :not_found)
          end

          def lease_attrs
            @lease_attrs ||= begin
              raw = params.require(:lease).permit(
                :credential,
                :type,
                :purpose,
                :tool_name,
                :expires_in,
                target: {}
              ).to_h.deep_symbolize_keys
              raw[:target] = plain_json(raw[:target] || {})
              raw
            end
          end

          def expires_in
            raw = lease_attrs[:expires_in]
            return ::CredentialStore::Broker::DEFAULT_LEASE_TTL if raw.blank?

            seconds = Integer(raw, exception: false)
            return ::CredentialStore::Broker::DEFAULT_LEASE_TTL unless seconds

            seconds.clamp(1, ::CredentialStore::Broker::DEFAULT_LEASE_TTL.to_i).seconds
          end
        end
      end
    end
  end
end
