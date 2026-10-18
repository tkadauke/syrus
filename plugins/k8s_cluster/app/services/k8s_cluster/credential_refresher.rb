require "json"
require "net/http"
require "uri"
require "yaml"

module K8sCluster
  class CredentialRefresher
    REFRESH_WINDOW = 15.minutes

    class RefreshError < StandardError; end

    def self.call(cluster, now: Time.current, http: Net::HTTP)
      new(cluster, now:, http:).call
    end

    def initialize(cluster, now:, http:)
      @cluster = cluster
      @now = now
      @http = http
    end

    def call
      cluster.with_lock do
        credential = ClusterCredential.credential_for(cluster)
        return :missing unless credential
        return :current if credential.expires_at.blank? || credential.expires_at > now + REFRESH_WINDOW

        refresh_locked!(credential)
      end
    end

    private

    attr_reader :cluster, :now, :http

    def refresh_locked!(credential)
      config = YAML.safe_load(credential.payload)
      user = current_user(config)
      oidc = oidc_config(user)
      unless oidc&.values_at("refresh-token", "client-id", "idp-issuer-url")&.all?(&:present?)
        status = credential.expires_at <= now ? "expired" : "expiring"
        cluster.update!(credential_refresh_status: status, credential_refresh_error: "Paste a replacement kubeconfig to rotate this credential", credential_refresh_attempted_at: now)
        return :operator_action_required
      end

      token_endpoint = discover_token_endpoint(oidc.fetch("idp-issuer-url"))
      response = post_refresh(token_endpoint, oidc)
      raise RefreshError, "identity provider rejected the credential refresh" unless response.is_a?(Net::HTTPSuccess)

      tokens = JSON.parse(response.body)
      oidc["id-token"] = tokens.fetch("id_token")
      oidc["refresh-token"] = tokens["refresh_token"] if tokens["refresh_token"].present?
      rotated = YAML.dump(config)
      parsed = KubeconfigParser.parse(rotated)
      raise RefreshError, "refreshed credential did not include a future expiry" unless parsed.expires_at && parsed.expires_at > now

      credential.update!(payload: rotated, expires_at: parsed.expires_at, last_rotated_at: now)
      audit!(credential, result: "allowed")
      cluster.update!(credential_refresh_status: "healthy", credential_refresh_error: nil, credential_refresh_attempted_at: now)
      :refreshed
    rescue RefreshError, JSON::ParserError, KeyError, Psych::Exception, URI::InvalidURIError,
      Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      cluster.update!(credential_refresh_status: "failed", credential_refresh_error: e.message, credential_refresh_attempted_at: now)
      audit!(credential, result: "failed") if credential&.persisted?
      :failed
    end

    def current_user(config)
      context_name = config.fetch("current-context")
      context = Array(config["contexts"]).find { |entry| entry["name"] == context_name }.fetch("context")
      Array(config["users"]).find { |entry| entry["name"] == context.fetch("user") }.fetch("user")
    end

    def oidc_config(user)
      provider = user["auth-provider"]
      provider["config"] if provider.is_a?(Hash) && provider["name"] == "oidc"
    end

    def discover_token_endpoint(issuer)
      uri = URI.parse("#{issuer.to_s.delete_suffix('/')}/.well-known/openid-configuration")
      response = http.get_response(uri)
      raise RefreshError, "identity provider discovery failed" unless response.is_a?(Net::HTTPSuccess)

      URI.parse(JSON.parse(response.body).fetch("token_endpoint"))
    end

    def post_refresh(uri, oidc)
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(
        "grant_type" => "refresh_token",
        "refresh_token" => oidc.fetch("refresh-token"),
        "client_id" => oidc.fetch("client-id"),
        "client_secret" => oidc["client-secret"]
      )
      http.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |connection| connection.request(request) }
    end

    def audit!(credential, result:)
      CredentialStore::CredentialAccessEvent.record!(
        credential: credential,
        surface: "api",
        action: "rotate",
        result: result,
        tool_name: "k8s_cluster_admin",
        purpose: "automatic Kubernetes credential refresh",
        metadata: { source: "k8s_cluster", actor: "system", automatic: true }
      )
    end
  end
end
