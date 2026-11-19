module Api::V1::App::ConnectedAccounts
  class OauthController < Api::V1::App::BaseController
    def start
      declaration = ::ConnectedAccounts::ProviderRegistry.fetch(params[:provider])
      available_scopes = declaration.connect_scope_keys
      scopes = Array(params[:scopes]).flat_map { |value| value.to_s.split(",") } & available_scopes
      scopes &= declaration.read_only_scope_keys if read_only?
      state, verifier = ::ConnectedAccounts::OauthState.issue!(user: Current.user, session_binding: session_binding,
        provider: declaration.key, requested_scopes: scopes, read_only: read_only?)
      result = declaration.call("authorization", ::ConnectedAccounts::Provider::AuthorizationContext.new(redirect_uri: callback_url(declaration),
        state:, requested_scopes: scopes, read_only: read_only?, code_verifier: verifier))
      redirect_to result.fetch(:authorize_url), allow_other_host: true
    rescue KeyError, ArgumentError
      redirect_to "/admin/connected_accounts", alert: I18n.t("connected_accounts.oauth.invalid_request")
    end

    def callback
      declaration = ::ConnectedAccounts::ProviderRegistry.fetch(params[:provider])
      if params[:error].present?
        ::ConnectedAccounts::OauthState.consume!(token: params.require(:state), user: Current.user,
          session_binding: session_binding, provider: declaration.key)
        return redirect_to("/admin/connected_accounts", alert: I18n.t("connected_accounts.oauth.denied"))
      end
      ::ConnectedAccounts::OauthBroker.complete!(provider: declaration.key, state: params.require(:state), code: params.require(:code),
        user: Current.user, session_binding: session_binding, redirect_uri: callback_url(declaration))
      redirect_to "/admin/connected_accounts", notice: I18n.t("connected_accounts.oauth.connected")
    rescue ActiveRecord::RecordNotFound, ActionController::ParameterMissing
      redirect_to "/admin/connected_accounts", alert: I18n.t("connected_accounts.oauth.invalid_state")
    rescue StandardError
      redirect_to "/admin/connected_accounts", alert: I18n.t("connected_accounts.oauth.failed")
    end

    private

    def read_only? = ActiveModel::Type::Boolean.new.cast(params[:read_only])
    def session_binding = (session[:connected_accounts_oauth_binding] ||= SecureRandom.urlsafe_base64(32))
    def callback_url(declaration) = "#{request.base_url}#{declaration.callback_route}"
  end
end
