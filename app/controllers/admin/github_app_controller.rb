module Admin
  class GithubAppController < BaseController
    # The manifest bounce and the GitHub callback run in the user's default
    # browser, which carries no Syrus session — the signed state token minted
    # by the register API is the credential for both.
    allow_unauthenticated_access only: %i[manifest callback]
    skip_before_action :require_admin, only: %i[manifest callback]

    GITHUB_MANIFEST_URL = "https://github.com/settings/apps/new".freeze

    # Session-free GET page that immediately re-submits the App manifest as a
    # POST to GitHub. This is the only way to deliver GitHub's manifest form
    # to the default browser: shell.openExternal can carry a URL but not a
    # POST body.
    def manifest
      payload = GithubAppManifestState.verify(params[:state])
      return render_state_error unless payload

      user = User.find_by(id: payload.user_id)
      return render_state_error unless user

      @github_manifest_url = "#{GITHUB_MANIFEST_URL}?state=#{CGI.escape(params[:state].to_s)}"
      @manifest_json = GithubAppManifest.new(user: user, callback_url: admin_github_app_callback_url).to_json
      render_for_user(user)
    end

    def callback
      payload = GithubAppManifestState.verify(params[:state])
      return render_state_error unless payload
      return render_state_error unless GithubAppManifestState.consume!(payload.nonce)

      code = params[:code].to_s
      user = User.find_by(id: payload.user_id)
      return render_state_error unless user
      return render_failure(I18n.t("github_app.errors.missing_code", locale: user.locale), user: user) if code.blank?

      conversion = GithubAppClient.manifest_conversion(code)
      persist_app_credentials!(conversion)
      SyncInstallationsJob.perform_later(payload.user_id)

      if payload.origin == "onboarding"
        # Started from the setup modal. Show a minimal success page that tries
        # to close itself; the modal polls and continues.
        render_for_user(user, :registered)
      else
        redirect_to admin_github_app_confirm_path, notice: I18n.t("github_app.registered.heading")
      end
    rescue Octokit::Error, Faraday::Error, JSON::ParserError => e
      render_failure(I18n.t("github_app.errors.registration_failed", error: e.message, locale: user&.locale.presence || I18n.default_locale), user: user)
    end

    private

    # Error pages must not redirect into the SPA: in the default-browser flow
    # there is no session there, so a redirect just lands on a login wall.
    def render_state_error
      @message = I18n.t("github_app.errors.invalid_link")
      render :error, layout: false, status: :unprocessable_entity
    end

    def render_failure(message, user: nil)
      @message = message
      render_for_user(user, :error, status: :unprocessable_entity)
    end

    def render_for_user(user, template = action_name, **options)
      locale = user&.locale.presence || I18n.default_locale
      I18n.with_locale(locale) do
        render template, **options.merge(layout: false)
      end
    end

    def persist_app_credentials!(payload)
      AppSetting.current.update!(
        github_app_id: payload.fetch("id"),
        github_app_slug: payload["slug"],
        github_app_private_key_pem: payload.fetch("pem"),
        github_app_registered_at: Time.current
      )
    end
  end
end
