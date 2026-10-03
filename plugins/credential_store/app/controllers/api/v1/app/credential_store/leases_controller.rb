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

          def ssh_agent
            context = require_runtime_context!
            return unless context

            metadata = nil
            material = nil
            ::CredentialStore::Broker.with_credential_env(
              context: context,
              credential: ssh_agent_attrs.fetch(:credential),
              type: ::CredentialStore::SshExec::SSH_PRIVATE_KEY_TYPE,
              env_key: "SYRUS_CREDENTIAL_STORE_SSH_PAYLOAD",
              purpose: ssh_agent_attrs[:purpose].presence || "ssh-agent command",
              tool_name: ssh_agent_attrs[:tool_name].presence || "credential.ssh-agent",
              target: ssh_agent_attrs[:target],
              expires_in: expires_in_for(ssh_agent_attrs[:expires_in])
            ) do |credential_env, lease_metadata|
              metadata = lease_metadata
              material = ::CredentialStore::SshKeyMaterial.from_payload(credential_env.fetch("SYRUS_CREDENTIAL_STORE_SSH_PAYLOAD"))
            end

            render json: {
              lease: metadata,
              ssh_key: {
                private_key: material.private_key,
                passphrase: material.passphrase
              }.compact
            }
          rescue ::CredentialStore::Broker::NotFound => e
            render_error("not_found", e.message, status: :not_found)
          rescue ::CredentialStore::Broker::Denied => e
            render_error("forbidden", e.message, status: :forbidden)
          rescue ::CredentialStore::SshExec::InvalidTarget => e
            render_error("bad_request", e.message, status: :bad_request)
          end

          def exec_material
            context = require_runtime_context!
            return unless context

            metadata = nil
            material = nil
            ::CredentialStore::Broker.with_credential_env(
              context: context,
              credential: exec_material_attrs.fetch(:credential),
              type: exec_material_attrs.fetch(:type),
              env_key: "SYRUS_CREDENTIAL_STORE_EXEC_PAYLOAD",
              purpose: exec_material_attrs[:purpose].presence || "credential exec command",
              tool_name: exec_material_attrs[:tool_name].presence || "credential.exec",
              target: exec_material_attrs[:target],
              expires_in: expires_in_for(exec_material_attrs[:expires_in])
            ) do |credential_env, lease_metadata|
              metadata = lease_metadata
              material = credential_env.fetch("SYRUS_CREDENTIAL_STORE_EXEC_PAYLOAD")
            end

            render json: { lease: metadata, material: { payload: material } }
          rescue ::CredentialStore::Broker::NotFound => e
            render_error("not_found", e.message, status: :not_found)
          rescue ::CredentialStore::Broker::Denied => e
            render_error("forbidden", e.message, status: :forbidden)
          end

          def exec_audit
            context = require_runtime_context!
            return unless context

            credential = visible_credential!(exec_audit_attrs.fetch(:credential))
            ::CredentialStore::CredentialAccessEvent.record!(
              credential: credential,
              user: context.user,
              repository: context.repository,
              job: context.job,
              workflow: context.workflow,
              run: context.run,
              chat_session: context.chat_session,
              surface: context.run? ? "workflow" : context.surface.to_s,
              tool_name: exec_audit_attrs[:tool_name].presence || "credential.exec",
              action: "use",
              purpose: exec_audit_attrs[:purpose].presence || "credential exec command",
              result: exec_audit_attrs[:exit_status].to_i.zero? ? "allowed" : "failed",
              metadata: exec_audit_metadata
            )

            head :no_content
          rescue ActiveRecord::RecordNotFound => e
            render_error("not_found", e.message, status: :not_found)
          end

          def ssh_agent_audit
            context = require_runtime_context!
            return unless context

            credential = visible_credential!(ssh_agent_audit_attrs.fetch(:credential))
            ::CredentialStore::CredentialAccessEvent.record!(
              credential: credential,
              user: context.user,
              repository: context.repository,
              job: context.job,
              workflow: context.workflow,
              run: context.run,
              chat_session: context.chat_session,
              surface: context.run? ? "workflow" : context.surface.to_s,
              tool_name: ssh_agent_audit_attrs[:tool_name].presence || "credential.ssh-agent",
              action: "use",
              purpose: ssh_agent_audit_attrs[:purpose].presence || "ssh-agent command",
              result: ssh_agent_audit_attrs[:exit_status].to_i.zero? ? "allowed" : "failed",
              metadata: ssh_agent_audit_metadata
            )

            head :no_content
          rescue ActiveRecord::RecordNotFound => e
            render_error("not_found", e.message, status: :not_found)
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
            expires_in_for(raw)
          end

          def expires_in_for(raw)
            return ::CredentialStore::Broker::DEFAULT_LEASE_TTL if raw.blank?

            seconds = Integer(raw, exception: false)
            return ::CredentialStore::Broker::DEFAULT_LEASE_TTL unless seconds

            seconds.clamp(1, ::CredentialStore::Broker::DEFAULT_LEASE_TTL.to_i).seconds
          end

          def require_runtime_context!
            current_invocation_context.tap do |context|
              unless context
                render_error("forbidden", "Credential leases require Syrus runtime CLI authentication.", status: :forbidden)
              end
            end
          end

          def ssh_agent_attrs
            @ssh_agent_attrs ||= begin
              raw = params.require(:ssh_agent).permit(
                :credential,
                :purpose,
                :tool_name,
                :expires_in,
                target: {}
              ).to_h.deep_symbolize_keys
              raw[:target] = plain_json(raw[:target] || {})
              raw
            end
          end

          def exec_material_attrs
            @exec_material_attrs ||= begin
              raw = params.require(:credential_exec).permit(
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

          def exec_audit_attrs
            @exec_audit_attrs ||= params.require(:credential_exec_audit).permit(
              :credential,
              :lease_id,
              :purpose,
              :tool_name,
              :exit_status,
              :duration_ms,
              :mode
            ).to_h.deep_symbolize_keys
          end

          def exec_audit_metadata
            {
              lease_id: exec_audit_attrs[:lease_id].presence,
              exit_status: exec_audit_attrs[:exit_status].to_i,
              duration_ms: exec_audit_attrs[:duration_ms].to_i,
              mode: exec_audit_attrs[:mode].presence
            }.compact
          end

          def ssh_agent_audit_attrs
            @ssh_agent_audit_attrs ||= params.require(:ssh_agent_audit).permit(
              :credential,
              :lease_id,
              :purpose,
              :tool_name,
              :exit_status,
              :duration_ms
            ).to_h.deep_symbolize_keys
          end

          def ssh_agent_audit_metadata
            {
              lease_id: ssh_agent_audit_attrs[:lease_id].presence,
              exit_status: ssh_agent_audit_attrs[:exit_status].to_i,
              duration_ms: ssh_agent_audit_attrs[:duration_ms].to_i
            }.compact
          end

          def visible_credential!(ref)
            relation = ::CredentialStore::Credential.all
            relation = ref.to_s.match?(/\A\d+\z/) ? relation.where(id: ref) : relation.where(name: ref.to_s)
            relation.detect { |credential| credential.scope_policy.usable_by?(credential, current_invocation_context) } || raise(ActiveRecord::RecordNotFound, "credential not found")
          end
        end
      end
    end
  end
end
