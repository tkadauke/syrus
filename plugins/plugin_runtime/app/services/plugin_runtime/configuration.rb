module PluginRuntime
  # Where the runtime's inputs come from. Environment rather than plugin
  # settings: the manager's address and token are facts about the deployment,
  # set by the Compose file or the Kubernetes manifest, and the token is a
  # secret that has no business sitting in the database.
  #
  # Which mode applies follows from what is set:
  #
  # - Managed (Docker Compose): SYRUS_PLUGIN_RUNTIME_URL and
  #   SYRUS_PLUGIN_RUNTIME_TOKEN point at the runtime manager, which pulls and
  #   starts each service.
  # - External (Kubernetes, or anything else): the operator deploys each
  #   service and sets SYRUS_PLUGIN_SERVICE_<NAME>_URL; Syrus only checks it
  #   answers.
  class Configuration
    MANAGER_URL = "SYRUS_PLUGIN_RUNTIME_URL".freeze
    MANAGER_TOKEN = "SYRUS_PLUGIN_RUNTIME_TOKEN".freeze

    def self.current = new(ENV)

    # "git-mirror" -> "SYRUS_PLUGIN_SERVICE_GIT_MIRROR_URL"
    def self.external_url_key(service_name)
      "SYRUS_PLUGIN_SERVICE_#{service_name.to_s.upcase.tr('-', '_')}_URL"
    end

    def initialize(env)
      @env = env
    end

    def manager_url = @env[MANAGER_URL].presence
    def manager_token = @env[MANAGER_TOKEN].presence

    def managed?
      manager_url.present? && manager_token.present?
    end

    def external_url(service_name)
      @env[self.class.external_url_key(service_name)].presence
    end
  end
end
