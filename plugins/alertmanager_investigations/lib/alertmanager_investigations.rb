module AlertmanagerInvestigations
  extend Syrus::PluginApi

  syrus_plugin "alertmanager_investigations" do
    display_name "Alertmanager Investigations"
    description "Polls Alertmanager firing alerts and files read-only investigation Jobs for alerts with git-backed runbooks."
    long_description "Alertmanager Investigations polls the Alertmanager API for firing alerts. " \
      "Alerts are escalated only when their runbook annotation resolves to a file in a registered " \
      "repository, so enabling autonomy for an alert is an explicit runbook change. The plugin " \
      "deduplicates by Alertmanager fingerprint and blocks concurrent investigations for the same host."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true
    tick_interval 1.minute

    config_schema [
      {
        key: "base_url",
        label: "Alertmanager URL",
        type: :string,
        required: false,
        description: "Base URL for Alertmanager. Falls back to ALERTMANAGER_URL."
      },
      {
        key: "bearer_token",
        label: "Bearer token",
        type: :secret_env,
        env_var: "ALERTMANAGER_BEARER_TOKEN",
        required: false,
        description: "Optional bearer token for Alertmanager."
      },
      {
        key: "rate_limit_minutes",
        label: "Fingerprint window",
        type: :integer,
        default: 30,
        required: false,
        description: "Minutes before the same alert fingerprint may file another investigation."
      },
      {
        key: "host_label",
        label: "Host label",
        type: :string,
        default: "instance",
        required: false,
        description: "Primary alert label used to prevent concurrent investigations for the same host."
      }
    ]

    provides callbacks: "AlertmanagerInvestigations::Callbacks"
  end
end
