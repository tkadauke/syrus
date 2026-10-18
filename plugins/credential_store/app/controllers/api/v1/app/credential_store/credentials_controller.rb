module Api
  module V1
    module App
      module CredentialStore
        class CredentialsController < BaseController
          before_action :require_credential_store_enabled

          def probe_host_key
            return unless authorize_enrollment_scope!("test")
            key = ::CredentialStore::SshHostKeyEnrollment.probe!(host: enrollment_params[:host], port: enrollment_params[:port])
            record_enrollment!("test", "allowed", key: key, source: "probe")
            render json: { enrollment: key.as_json }
          rescue ::CredentialStore::SshExec::Error => e
            record_enrollment!("test", "failed", error: e, source: "probe")
            render_error("ssh_host_key_probe_failed", e.message, status: :unprocessable_content)
          end

          def inspect_host_key
            return unless authorize_enrollment_scope!("test")
            key = ::CredentialStore::SshHostKeyEnrollment.manual!(host: enrollment_params[:host], port: enrollment_params[:port], known_host: enrollment_params[:known_host])
            record_enrollment!("test", "allowed", key: key, source: "manual")
            render json: { enrollment: key.as_json }
          rescue ::CredentialStore::SshExec::Error => e
            record_enrollment!("test", "failed", error: e, source: "manual")
            render_error("ssh_known_host_invalid", e.message, status: :unprocessable_content)
          end

          def confirm_host_key
            return unless authorize_enrollment_scope!("update")
            key = ::CredentialStore::SshHostKeyEnrollment.manual!(host: enrollment_params[:host], port: enrollment_params[:port], known_host: enrollment_params[:known_host])
            credential = enrollment_credential
            if credential
              metadata = credential.safe_metadata.to_h.merge("host" => key.host, "port" => key.port, "known_host" => key.known_host, "fingerprint" => key.fingerprint)
              credential.update!(safe_metadata: metadata)
            end
            record_enrollment!("update", "allowed", key: key, source: "confirmation", credential: credential)
            render json: { enrollment: key.as_json, credential: credential && ::CredentialStore::ManagementPayload.credential_json(credential, user: Current.user) }
          rescue ::CredentialStore::SshExec::Error, ActiveRecord::RecordInvalid => e
            record_enrollment!("update", "failed", error: e, source: "confirmation")
            render_error("ssh_host_key_confirmation_failed", e.message, status: :unprocessable_content)
          end

          def index
            render json: payload_for(visible_credentials)
          end

          def show
            credential = find_visible_credential
            render json: {
              credential: ::CredentialStore::ManagementPayload.credential_json(credential, user: Current.user),
              options: payload_for([]).fetch(:options)
            }
          end

          def create
            attrs = credential_attrs
            unless authorization.can_manage_scope?(attrs[:scope_type], attrs[:scope_id])
              render_error("forbidden", "You cannot manage credentials for that scope.", status: :forbidden)
              return
            end

            credential = ::CredentialStore::Credential.new(attrs.merge(
              created_by: Current.user,
              owner_user: attrs[:scope_type] == "user" ? User.find_by(id: attrs[:scope_id]) : Current.user,
              last_rotated_at: Time.current
            ))
            if credential.save
              record_change!(credential, "create", before: nil, after: audit_snapshot(credential), payload_replaced: true)
              render json: payload_for(visible_credentials.reload).merge(message: "Credential created."), status: :created
            else
              render_error("validation_failed", credential.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          end

          def update
            credential = find_visible_credential
            return unless authorize_credential!(credential)

            attrs = credential_attrs(require_payload: false)
            unless authorization.can_manage_scope?(attrs[:scope_type], attrs[:scope_id])
              render_error("forbidden", "You cannot move credentials into that scope.", status: :forbidden)
              return
            end
            attrs[:last_rotated_at] = Time.current if attrs.key?(:payload)
            before = audit_snapshot(credential)
            if credential.update(attrs)
              record_change!(credential, "update", before: before, after: audit_snapshot(credential), payload_replaced: attrs.key?(:payload))
              render json: payload_for(visible_credentials.reload).merge(message: "Credential updated.")
            else
              render_error("validation_failed", credential.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          end

          def rotate
            credential = find_visible_credential
            return unless authorize_credential!(credential)

            payload = params.dig(:credential, :payload).to_s
            if payload.blank?
              render_error("validation_failed", "Payload can't be blank.", status: :unprocessable_content)
              return
            end

            was_revoked = credential.revoked?
            if credential.update(payload: payload, last_rotated_at: Time.current, revoked_at: nil)
              ::CredentialStore::CredentialAccessEvent.record!(
                credential: credential,
                user: Current.user,
                surface: "admin",
                action: "rotate",
                result: "allowed",
                metadata: { payload_replaced: true, unrevoked: was_revoked }
              )
              render json: payload_for(visible_credentials.reload).merge(message: "Credential rotated.")
            else
              render_error("validation_failed", credential.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          end

          def revoke
            credential = find_visible_credential
            return unless authorize_credential!(credential)

            credential.update!(revoked_at: Time.current)
            ::CredentialStore::CredentialAccessEvent.record!(
              credential: credential,
              user: Current.user,
              surface: "admin",
              action: "revoke",
              result: "allowed"
            )
            render json: payload_for(visible_credentials.reload).merge(message: "Credential revoked.")
          end

          private

          def enrollment_params
            @enrollment_params ||= params.require(:enrollment).permit(:credential_id, :scope_type, :scope_id, :host, :port, :known_host).to_h.symbolize_keys
          end

          def enrollment_credential
            return @enrollment_credential if defined?(@enrollment_credential)
            @enrollment_credential = enrollment_params[:credential_id].present? ? visible_credentials.find(enrollment_params[:credential_id]) : nil
          end

          def authorize_enrollment_scope!(action)
            if enrollment_params[:credential_id].present?
              credential = visible_credentials.find_by(id: enrollment_params[:credential_id])
              return deny_enrollment!(action) unless credential && authorization.can_manage?(credential)
              @enrollment_credential = credential
            elsif !authorization.can_manage_scope?(enrollment_params[:scope_type], enrollment_params[:scope_id])
              return deny_enrollment!(action)
            end
            true
          end

          def deny_enrollment!(action)
            ::CredentialStore::CredentialAccessEvent.record!(credential: nil, user: Current.user, surface: "admin", action: action, result: "denied",
              denial_reason: "not authorized to enroll an SSH host key", metadata: { operation: "ssh_host_key_enrollment" })
            render_error("forbidden", "You cannot manage SSH host keys for that scope.", status: :forbidden)
            false
          end

          def record_enrollment!(action, result, key: nil, error: nil, source:, credential: enrollment_credential)
            ::CredentialStore::CredentialAccessEvent.record!(credential: credential, user: Current.user, surface: "admin", action: action, result: result,
              metadata: { operation: "ssh_host_key_enrollment", source: source, host: key&.host || enrollment_params[:host], port: key&.port || enrollment_params[:port], fingerprint: key&.fingerprint, error_class: error&.class&.name }.compact)
          end

          def require_credential_store_enabled
            return if ::CredentialStore.enabled?

            render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: "credential_store"), status: :not_found)
          end

          def visible_credentials
            @visible_credentials ||= authorization.visible_scope
              .includes(:created_by, :owner_user)
              .order(revoked_at: :asc, updated_at: :desc, id: :desc)
          end

          def find_visible_credential
            visible_credentials.find(params[:id])
          end

          def authorization
            @authorization ||= ::CredentialStore::ManagementAuthorization.new(Current.user)
          end

          def authorize_credential!(credential)
            return true if authorization.can_manage?(credential)

            render_error("forbidden", "You cannot manage this credential.", status: :forbidden)
            false
          end

          def payload_for(credentials)
            ::CredentialStore::ManagementPayload.new(user: Current.user, credentials: credentials).as_json
          end

          def credential_attrs(require_payload: true)
            raw = params.require(:credential).permit(
              :name,
              :description,
              :credential_type,
              :scope_type,
              :scope_id,
              :payload,
              :expires_at,
              safe_metadata: {},
              target_constraints: {},
              allowed_surfaces: [],
              allowed_tools: []
            ).to_h.deep_symbolize_keys
            raw[:scope_id] = nil if raw[:scope_type].to_s == "instance" || raw[:scope_id].blank?
            raw.delete(:payload) if !require_payload && raw[:payload].blank?
            raw
          end

          def audit_snapshot(credential)
            credential.slice(:scope_type, :scope_id, :allowed_surfaces, :allowed_tools, :target_constraints, :revoked_at)
          end

          def record_change!(credential, action, before:, after:, payload_replaced:)
            ::CredentialStore::CredentialAccessEvent.record!(
              credential: credential, user: Current.user, surface: "admin", action: action, result: "allowed",
              metadata: { before: before, after: after, payload_replaced: payload_replaced }
            )
          end
        end
      end
    end
  end
end
