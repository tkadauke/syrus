module Api
  module V1
    module App
      class CredentialsController < BaseController
        def show
          render json: credentials_payload(Current.user)
        end

        def update
          attrs = credentials_params.to_h.reject { |key, value| blank_write_only_value?(key, value) }

          if Current.user.update(attrs)
            render json: credentials_payload(Current.user.reload).merge(message: "Credentials updated.")
          else
            render_error("validation_failed", Current.user.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        def clear_credential
          credential = params[:credential].to_s
          label = User::CLEARABLE_CREDENTIALS[credential]
          unless label
            render_error("unknown_credential", "Unknown credential.", status: :unprocessable_content)
            return
          end

          Current.user.clear_credential!(credential)
          render json: credentials_payload(Current.user.reload).merge(message: "#{label} cleared.")
        end

        def test_credential
          credential = params[:credential].to_s
          unless testable_credentials.include?(credential)
            render_error("unknown_credential", "Unknown credential.", status: :unprocessable_content)
            return
          end

          result = CredentialProbe.call(user: Current.user, credential: credential)
          render json: {
            credential_test: result.as_json,
            message: result.message
          }
        end

        def rotate_api_token
          unless Current.user.admin?
            render_error("forbidden", "API token is admin-only.", status: :forbidden)
            return
          end

          new_token = Current.user.generate_api_token!
          render json: credentials_payload(Current.user.reload).merge(
            message: "API token rotated. Copy it now; it won't be shown again.",
            new_api_token: new_token
          )
        end

        def revoke_api_token
          unless Current.user.admin?
            render_error("forbidden", "API token is admin-only.", status: :forbidden)
            return
          end

          Current.user.revoke_api_token!
          render json: credentials_payload(Current.user.reload).merge(message: "API token revoked.")
        end

        private

        def credentials_payload(user)
          {
            user: user_json(user),
            credential_status: credential_status_json(user),
            github_rate_limit: github_rate_limit_json(user),
            options: credentials_options
          }
        end

        def documents_payload(user)
          {
            documents: user.documents.with_attached_file.order(:created_at, :id).map { |document| document_json(document) }
          }
        end

        def user_json(user)
          {
            id: user.id,
            email_address: user.email_address,
            name: user.name,
            first_name: user.first_name,
            last_name: user.last_name,
            profile_location: user.profile_location,
            profile_company: user.profile_company,
            profile_website: user.profile_website,
            display_name: user.display_name,
            github_handle: user.github_handle,
            profile_bio: user.profile_bio,
            avatar_url: user.avatar_url,
            admin: user.admin?,
            agent_provider: user.agent_provider,
            codex_auth_mode: user.codex_auth_mode,
            agent_max_turns: user.agent_max_turns,
            scheduling_paused: user.scheduling_paused,
            auto_approve_mode: user.auto_approve_mode
          }
        end

        def credential_status_json(user)
          {
            github_token: user.github_token.present?,
            claude_oauth_token: user.claude_oauth_token.present?,
            codex_api_key: user.codex_api_key.present?,
            codex_auth_json: user.codex_auth_json.present?,
            api_token: user.admin? ? user.api_token.present? : nil
          }
        end

        def github_rate_limit_json(user)
          return nil unless user.gh_rate_limit_observed_at

          {
            remaining: user.gh_rate_limit_remaining,
            limit: user.gh_rate_limit_limit,
            resource: user.gh_rate_limit_resource || "core",
            reset_at: user.gh_rate_limit_reset_at&.iso8601,
            observed_at: user.gh_rate_limit_observed_at&.iso8601
          }
        end

        def document_json(document)
          {
            id: document.id,
            kind: document.kind,
            google_doc_url: document.google_doc_url,
            filename: document.filename,
            content_type: document.content_type,
            byte_size: document.byte_size,
            created_at: document.created_at.iso8601
          }
        end

        def credentials_options
          {
            agent_providers: User::AGENT_PROVIDERS,
            codex_auth_modes: User::CODEX_AUTH_MODES,
            agent_max_turns: {
              min: User::AGENT_MAX_TURNS_RANGE.first,
              max: User::AGENT_MAX_TURNS_RANGE.last
            },
            clearable_credentials: User::CLEARABLE_CREDENTIALS.map do |value, label|
              { value: value, label: label }
            end,
            auto_approve_modes: [
              { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
              { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." },
              { value: "if_graders_pass_and_tagged_safe", label: "If graders pass and tagged safe", preview: "Jobs using this rule also need the safe tag before landing." }
            ]
          }
        end

        def testable_credentials
          %w[ github_token claude_oauth_token codex_api_key codex_auth_json ]
        end

        def credentials_params
          params.expect(user: [ :name, :first_name, :last_name, :github_handle, :profile_bio, :avatar_url,
                                :profile_company, :profile_website,
                                :profile_location, :agent_provider, :claude_oauth_token, :codex_auth_mode,
                                :codex_api_key, :codex_auth_json, :github_token,
                                :agent_max_turns, :scheduling_paused, :auto_approve_mode ])
        end

        def blank_write_only_value?(key, value)
          User::CLEARABLE_CREDENTIALS.key?(key.to_s) && (value.nil? || (value.is_a?(String) && value.blank?))
        end
      end
    end
  end
end
