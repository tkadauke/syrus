module Api
  module V1
    module App
      module CredentialStore
        class LeasesController < BaseController
          class InvalidAudit < StandardError; end

          before_action :require_credential_store_enabled
          rescue_from ::CredentialStore::Broker::Ambiguous, with: :render_ambiguous_credential

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
              tool_name: "credential.ssh-agent",
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
              tool_name: "credential.exec",
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

            credential, lease_event, exit_status = validate_completion_audit!(
              exec_audit_attrs, context: context, expected_tool: "credential.exec"
            )
            ::CredentialStore::CredentialAccessEvent.record!(
              credential: credential,
              user: context.user,
              repository: context.repository,
              job: context.job,
              workflow: context.workflow,
              run: context.run,
              chat_session: context.chat_session,
              surface: context.run? ? "workflow" : context.surface.to_s,
              tool_name: "credential.exec",
              action: "use",
              purpose: exec_audit_attrs[:purpose].presence || "credential exec command",
              result: exit_status.zero? ? "allowed" : "failed",
              metadata: exec_audit_metadata.merge(lease_event_id: lease_event.id, exit_status: exit_status),
              completion_of_event: lease_event
            )

            head :no_content
          rescue ActiveRecord::RecordNotFound => e
            render_error("not_found", e.message, status: :not_found)
          rescue InvalidAudit => e
            render_error("validation_failed", e.message, status: :unprocessable_content)
          rescue ActiveRecord::RecordNotUnique
            render_error("validation_failed", "lease completion was already recorded", status: :unprocessable_content)
          end

          def ssh_agent_audit
            context = require_runtime_context!
            return unless context

            credential, lease_event, exit_status = validate_completion_audit!(
              ssh_agent_audit_attrs, context: context, expected_tool: "credential.ssh-agent"
            )
            ::CredentialStore::CredentialAccessEvent.record!(
              credential: credential,
              user: context.user,
              repository: context.repository,
              job: context.job,
              workflow: context.workflow,
              run: context.run,
              chat_session: context.chat_session,
              surface: context.run? ? "workflow" : context.surface.to_s,
              tool_name: "credential.ssh-agent",
              action: "use",
              purpose: ssh_agent_audit_attrs[:purpose].presence || "ssh-agent command",
              result: exit_status.zero? ? "allowed" : "failed",
              metadata: ssh_agent_audit_metadata.merge(lease_event_id: lease_event.id, exit_status: exit_status),
              completion_of_event: lease_event
            )

            head :no_content
          rescue ActiveRecord::RecordNotFound => e
            render_error("not_found", e.message, status: :not_found)
          rescue InvalidAudit => e
            render_error("validation_failed", e.message, status: :unprocessable_content)
          rescue ActiveRecord::RecordNotUnique
            render_error("validation_failed", "lease completion was already recorded", status: :unprocessable_content)
          end

          private

          def render_ambiguous_credential(error)
            render_error("conflict", error.message, status: :conflict)
          end

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
              duration_ms: ssh_agent_audit_attrs[:duration_ms].to_i
            }.compact
          end

          def validate_completion_audit!(attrs, context:, expected_tool:)
            lease_id = attrs[:lease_id].to_s
            raise InvalidAudit, "lease_id is required" if lease_id.blank?
            raise InvalidAudit, "tool_name does not match the lease tool" if attrs[:tool_name].present? && attrs[:tool_name] != expected_tool

            exit_status = Integer(attrs[:exit_status], exception: false)
            raise InvalidAudit, "exit_status must be an integer" if exit_status.nil?

            event = ::CredentialStore::CredentialAccessEvent.find_by(
              action: "lease", result: "allowed", tool_name: expected_tool, lease_id: lease_id
            )
            raise InvalidAudit, "lease was not issued for this credential and tool" unless event&.credential
            credential = event.credential
            raise InvalidAudit, "lease was not issued for this credential and tool" unless credential_ref_matches?(attrs.fetch(:credential), credential)
            raise InvalidAudit, "lease does not belong to this runtime context" unless audit_context_matches?(event, context)
            raise InvalidAudit, "lease completion was already recorded" if ::CredentialStore::CredentialAccessEvent.exists?(completion_of_event: event)

            expires_at = Time.iso8601(event.metadata.fetch("expires_at"))
            raise InvalidAudit, "lease has expired" if Time.current >= expires_at

            [ credential, event, exit_status ]
          rescue KeyError, ArgumentError
            raise InvalidAudit, "lease metadata is invalid"
          end

          def credential_ref_matches?(reference, credential)
            reference.to_s == credential.id.to_s || reference.to_s == credential.name
          end

          def audit_context_matches?(event, context)
            event.user_id == context.user&.id &&
              event.repository_id == context.repository&.id &&
              event.job_id == context.job&.id &&
              event.workflow_id == context.workflow&.id &&
              event.run_id == context.run&.id &&
              event.chat_session_id == context.chat_session&.id
          end
        end
      end
    end
  end
end
