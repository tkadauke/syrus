module Api
  module V1
    module App
      module CredentialStore
        class CredentialsController < BaseController
          before_action :require_credential_store_enabled

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
            if credential.update(attrs)
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

            if credential.update(payload: payload, last_rotated_at: Time.current, revoked_at: nil)
              ::CredentialStore::CredentialAccessEvent.record!(
                credential: credential,
                user: Current.user,
                surface: "admin",
                action: "rotate",
                result: "allowed"
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
        end
      end
    end
  end
end
