module AgentActivity
  module SmartFolders
    SUBJECT = "agent_session"

    BUILTINS = [
      { key: "agent_activity_all", name: "All", visibility: :always, filter: { "and" => [] } },
      { key: "agent_activity_running", name: "Running", visibility: :always, filter: { "and" => [ { "field" => "status", "op" => "is", "value" => "running" } ] } },
      { key: "agent_activity_failed", name: "Failed", visibility: :when_present, filter: { "and" => [ { "field" => "status", "op" => "is", "value" => "failed" } ] } }
    ].freeze

    module_function

    def install_into(scope)
      scope.effect("agent_activity smart folders") do
        ::SmartFolder.register_subject!(
          SUBJECT,
          builtins: BUILTINS,
          label: "Agent Activity",
          path: ->(**query) { path(**query) }
        )
      end
    end

    def path(**query)
      params = query.compact_blank
      params.empty? ? "/agent_activity" : "/agent_activity?#{params.to_query}"
    end

    def default_folder
      ::SmartFolder.ensure_builtins_for_subject!(SUBJECT)
      ::SmartFolder.builtins(SUBJECT).find_by(name: "Running")
    end
  end
end
