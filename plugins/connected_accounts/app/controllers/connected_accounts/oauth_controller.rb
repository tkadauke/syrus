module ConnectedAccounts
  class OauthController < ApplicationController
    def start
      declaration = ProviderRegistry.fetch(params[:provider])
      scopes = Array(params[:scopes]).flat_map { |value| value.to_s.split(",") } & declaration.scopes.pluck("key")
      scopes &= declaration.scopes.filter_map { |scope| scope["key"] if scope["key"].match?(/read/i) } if read_only?
      state, verifier = OauthState.issue!(user: Current.user, session_binding: session_binding, provider: declaration.key, requested_scopes: scopes, read_only: read_only?)
      result = declaration.call("authorization", Provider::AuthorizationContext.new(redirect_uri: callback_url(declaration), state: state,
        requested_scopes: scopes, read_only: read_only?, code_verifier: verifier))
      redirect_to result.fetch(:authorize_url), allow_other_host: true
    rescue KeyError, ArgumentError
      redirect_to "/settings/connected_accounts", alert: I18n.t("connected_accounts.oauth.invalid_request")
    end

    def callback
      return redirect_to("/settings/connected_accounts", alert: I18n.t("connected_accounts.oauth.denied")) if params[:error].present?
      declaration = ProviderRegistry.fetch(params[:provider])
      OauthBroker.complete!(provider: declaration.key, state: params.require(:state), code: params.require(:code), user: Current.user,
        session_binding: session_binding, redirect_uri: callback_url(declaration))
      redirect_to "/settings/connected_accounts", notice: I18n.t("connected_accounts.oauth.connected")
    rescue ActiveRecord::RecordNotFound, ActionController::ParameterMissing
      redirect_to "/settings/connected_accounts", alert: I18n.t("connected_accounts.oauth.invalid_state")
    rescue StandardError
      redirect_to "/settings/connected_accounts", alert: I18n.t("connected_accounts.oauth.failed")
    end

    private

    def read_only? = ActiveModel::Type::Boolean.new.cast(params[:read_only])
    def session_binding = (session[:connected_accounts_oauth_binding] ||= SecureRandom.urlsafe_base64(32))
    def callback_url(declaration) = "#{request.base_url}#{declaration.callback_route}"
  end
end
