module Api
  module V1
    module App
      class CredentialsController < BaseController
        # Scopes a classic GitHub PAT must carry for Syrus to clone, branch,
        # open PRs, and update GitHub Actions workflows.
        GITHUB_REQUIRED_SCOPES = %w[ repo workflow ].freeze

        def show
          render json: credentials_payload(Current.user)
        end

        def update
          attrs = credentials_params.to_h.reject { |key, value| blank_write_only_value?(key, value) }
          notification_preferences = attrs.delete("notification_preferences")
          merge_desktop_notification_preferences!(Current.user, notification_preferences) if notification_preferences.present?

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

        # Validate a pasted-but-unsaved GitHub token (onboarding modal). Probes
        # GitHub and reports whether the token authenticates and carries the
        # scopes Syrus needs before the operator commits it.
        def test_github_token
          result = CredentialProbe.github_token(
            token: params[:github_token].to_s,
            required_scopes: GITHUB_REQUIRED_SCOPES
          )
          render json: {
            credential_test: result.as_json,
            message: result.message
          }
        end

        # Preflight: does `claude --print` already work on this machine using
        # the operator's local Claude login? Lets the wizard skip token setup
        # for bare-metal subscribers.
        def test_claude_cli
          result = CredentialProbe.claude_cli_ready(user: Current.user)
          render json: { credential_test: result.as_json, message: result.message }
        end

        # Start the Claude subscription OAuth flow. Generates PKCE material,
        # stashes it in the session, and returns the authorize URL the modal
        # opens. Uses the provider-hosted paste callback (the only redirect the
        # client whitelists), so the authorize page shows a code to copy back.
        def claude_oauth_start
          flow = ClaudeOauth.begin(redirect_uri: ClaudeOauth::PASTE_REDIRECT_URI)
          session[:claude_oauth] = {
            "verifier" => flow.verifier,
            "state" => flow.state,
            "redirect_uri" => flow.redirect_uri
          }
          render json: { authorize_url: flow.authorize_url }
        end

        # Finish the Claude OAuth flow: exchange the pasted code (raw or the
        # `code#state` form the provider shows) for a long-lived token, save it,
        # and test it. Requires a prior claude_oauth_start in this session.
        def claude_oauth_exchange
          stash = session[:claude_oauth].to_h
          if stash["verifier"].blank?
            render_error("oauth_not_started", "Start the Claude authorization first.", status: :unprocessable_content)
            return
          end

          token = ClaudeOauth.exchange(
            code: params[:code].to_s,
            verifier: stash["verifier"],
            state: stash["state"],
            redirect_uri: stash["redirect_uri"]
          )
          Current.user.update!(claude_oauth_token: token)
          session.delete(:claude_oauth)

          probe = CredentialProbe.call(user: Current.user, credential: "claude_oauth_token")
          render json: { credential_test: probe.as_json, message: probe.message }
        rescue ClaudeOauth::Error => e
          render_error("oauth_exchange_failed", e.message, status: :unprocessable_content)
        end

        def codex_oauth_start
          flow = CodexOauth.begin(redirect_uri: CodexOauth::PASTE_REDIRECT_URI)
          session[:codex_oauth] = {
            "verifier" => flow.verifier,
            "state" => flow.state,
            "redirect_uri" => flow.redirect_uri
          }
          listener_started = CodexOauth.start_callback_listener(user: Current.user)
          render json: { authorize_url: flow.authorize_url, listener_started: listener_started }
        end

        def codex_oauth_exchange
          stash = session[:codex_oauth].to_h
          if stash["verifier"].blank?
            render_error("oauth_not_started", "Start the ChatGPT authorization first.", status: :unprocessable_content)
            return
          end

          auth_json = CodexOauth.exchange(
            code: params[:code].to_s,
            verifier: stash["verifier"],
            state: stash["state"],
            redirect_uri: stash["redirect_uri"]
          )
          Current.user.update!(codex_auth_mode: "chatgpt_login", codex_auth_json: auth_json)
          session.delete(:codex_oauth)

          probe = CredentialProbe.call(user: Current.user, credential: "codex_auth_json")
          render json: { credential_test: probe.as_json, message: probe.message }
        rescue CodexOauth::Error => e
          render_error("oauth_exchange_failed", e.message, status: :unprocessable_content)
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
            options: credentials_options(user)
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
            role: user.role,
            agent_provider: user.agent_provider,
            chat_provider: user.chat_provider,
            codex_auth_mode: user.codex_auth_mode,
            agent_max_turns: user.agent_max_turns,
            scheduling_paused: user.scheduling_paused,
            auto_approve_mode: user.auto_approve_mode,
            notification_preferences: {
              desktop_job_implemented: user.desktop_notification_enabled?(:desktop_job_implemented),
              desktop_job_failed: user.desktop_notification_enabled?(:desktop_job_failed)
            }
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

        def credentials_options(user)
          {
            agent_providers: User::AGENT_PROVIDERS,
            chat_providers: User::CHAT_PROVIDERS.select { |provider| user.chat_provider_configured?(provider) },
            roles: User::ROLES,
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
                                :profile_location, :role, :agent_provider, :chat_provider, :claude_oauth_token, :codex_auth_mode,
                                :codex_api_key, :codex_auth_json, :github_token,
                                :agent_max_turns, :scheduling_paused, :auto_approve_mode,
                                { notification_preferences: [ :desktop_job_implemented, :desktop_job_failed ] } ])
        end

        def blank_write_only_value?(key, value)
          User::CLEARABLE_CREDENTIALS.key?(key.to_s) && (value.nil? || (value.is_a?(String) && value.blank?))
        end

        def merge_desktop_notification_preferences!(user, preferences)
          permitted = ActionController::Parameters.new(preferences)
                                                   .permit(:desktop_job_implemented, :desktop_job_failed)
                                                   .to_h
          return if permitted.empty?

          boolean = ActiveModel::Type::Boolean.new
          current = user.read_attribute(:notification_preferences)
          current = {} unless current.is_a?(Hash)
          user.write_attribute(
            :notification_preferences,
            current.merge(permitted.transform_values { |value| boolean.cast(value) })
          )
        end
      end
    end
  end
end
