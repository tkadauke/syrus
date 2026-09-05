require "yaml"

module K8sCluster
  # Resolves a pasted kubeconfig YAML's current-context to a single
  # cluster/user pair and extracts only the connection info Syrus needs
  # (server URL + whichever auth material the context's user carries).
  # The raw, possibly multi-context kubeconfig is never persisted -- only
  # this resolved result is.
  class KubeconfigParser
    class ParseError < StandardError; end

    Result = Data.define(:api_server_url, :credentials)

    def self.parse(kubeconfig_yaml)
      new(kubeconfig_yaml).parse
    end

    def initialize(kubeconfig_yaml)
      @kubeconfig_yaml = kubeconfig_yaml
    end

    def parse
      config = load_yaml
      context_name, context = current_context(config)
      cluster = cluster_for(config, context["cluster"], context_name)
      user = user_for(config, context["user"], context_name)

      server = cluster["server"]
      raise ParseError, "cluster #{context['cluster'].inspect} has no server URL" if server.blank?

      Result.new(api_server_url: server, credentials: credentials_for(cluster, user))
    end

    private

    def load_yaml
      raise ParseError, "kubeconfig is blank" if @kubeconfig_yaml.blank?

      config = YAML.safe_load(@kubeconfig_yaml, permitted_classes: [ Date, Time ])
      raise ParseError, "kubeconfig is not a valid kubeconfig document" unless config.is_a?(Hash)

      config
    rescue Psych::SyntaxError => e
      raise ParseError, "kubeconfig is not valid YAML: #{e.message}"
    end

    def current_context(config)
      name = config["current-context"]
      raise ParseError, "kubeconfig has no current-context set" if name.blank?

      entry = Array(config["contexts"]).find { |candidate| candidate["name"] == name }
      raise ParseError, "current-context #{name.inspect} not found in kubeconfig contexts" unless entry

      context = entry["context"] || {}
      raise ParseError, "context #{name.inspect} has no cluster set" if context["cluster"].blank?
      raise ParseError, "context #{name.inspect} has no user set" if context["user"].blank?

      [ name, context ]
    end

    def cluster_for(config, name, context_name)
      entry = Array(config["clusters"]).find { |candidate| candidate["name"] == name }
      raise ParseError, "context #{context_name.inspect} references cluster #{name.inspect}, which is not defined" unless entry

      entry["cluster"] || {}
    end

    def user_for(config, name, context_name)
      entry = Array(config["users"]).find { |candidate| candidate["name"] == name }
      raise ParseError, "context #{context_name.inspect} references user #{name.inspect}, which is not defined" unless entry

      entry["user"] || {}
    end

    def credentials_for(cluster, user)
      credentials = auth_credentials_for(user)
      credentials["ca_data"] = cluster["certificate-authority-data"] if cluster["certificate-authority-data"].present?
      credentials
    end

    def auth_credentials_for(user)
      if user["token"].present?
        { "token" => user["token"] }
      elsif user["client-certificate-data"].present? && user["client-key-data"].present?
        { "client_cert" => user["client-certificate-data"], "client_key" => user["client-key-data"] }
      elsif user["exec"].present?
        raise ParseError, "user uses an exec-based credential plugin (e.g. aws-iam-authenticator, gke-gcloud-auth-plugin), which Syrus cannot run; " \
                          "use a context whose user has an inline bearer token or client-certificate-data/client-key-data instead"
      elsif user["client-certificate"].present? || user["client-key"].present? || user["tokenFile"].present?
        raise ParseError, "user credentials reference external files, not inline data; paste a kubeconfig with " \
                          "certificate-authority-data/client-certificate-data/client-key-data embedded"
      else
        raise ParseError, "user has no supported credentials (expected a bearer token, or client-certificate-data + client-key-data)"
      end
    end
  end
end
