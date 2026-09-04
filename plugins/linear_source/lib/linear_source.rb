module SyrusLinearSource
  extend Syrus::PluginApi

  syrus_plugin "linear_source" do
    display_name "Linear Source"
    description "Ingests Linear issues as Syrus jobs and epics."
    long_description "Linear Source connects Syrus to Linear teams and issues. It lets operators ingest Linear work into Syrus jobs and epics while preserving Linear as the planning system of record.\n\nThe plugin is disabled by default because it requires Linear credentials and team selection. It complements GitHub Source: Linear can provide the work intake while GitHub remains the code and PR backend."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/linear_source.svg"
    author "Thomas Kadauke"
    category "input_source"
    default_enabled false
    disableable true
    provides input_source: "InputSources::Linear"
    route :get, "/api/v1/app/linear/teams", to: "api/v1/app/linear#teams"
  end
end
