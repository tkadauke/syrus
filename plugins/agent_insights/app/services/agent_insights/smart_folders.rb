module AgentInsights
  module SmartFolders
    SUBJECT = "agent_insight"

    BUILTINS = [
      { key: "agent_insights_pending", name: "Pending", visibility: :always, filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "pending" } ] } },
      { key: "agent_insights_accepted", name: "Accepted", visibility: :always, filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "accepted" } ] } },
      { key: "agent_insights_dismissed", name: "Dismissed", visibility: :always, filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "dismissed" } ] } },
      { key: "agent_insights_retired", name: "Retired", visibility: :always, filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "retired" } ] } },
      { key: "agent_insights_all", name: "All", visibility: :always, filter: { "and" => [] } }
    ].freeze

    CHIPS = {
      "state" => "Filters::Chips::AgentInsights::State",
      "severity" => "Filters::Chips::AgentInsights::Severity",
      "proposal_type" => "Filters::Chips::AgentInsights::ProposalType",
      "category" => "Filters::Chips::AgentInsights::Category",
      "confidence" => "Filters::Chips::AgentInsights::Confidence",
      "created_job_present" => "Filters::Chips::AgentInsights::CreatedJobPresent",
      "created_at" => "Filters::Chips::CreatedAt"
    }.freeze

    module_function

    def install_into(scope)
      scope.effect("agent_insights filter subject") do
        Filters.register_subject(name: SUBJECT, model: AgentInsights::Suggestion, chips: CHIPS)
      end
      scope.effect("agent_insights smart folders") do
        ::SmartFolder.register_subject!(
          SUBJECT,
          builtins: BUILTINS,
          label: "Agent Insights",
          path: ->(**query) { path(**query) }
        )
      end
    end

    def path(**query)
      params = query.compact_blank
      params.empty? ? "/agent_insights" : "/agent_insights?#{params.to_query}"
    end

    def default_folder
      ::SmartFolder.ensure_builtins_for_subject!(SUBJECT)
      ::SmartFolder.builtins(SUBJECT).find_by(name: "Pending")
    end
  end
end
