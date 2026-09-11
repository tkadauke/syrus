module AgentInsights
  module FilterSubject
    CHIPS = {
      "state" => "Filters::Chips::AgentInsights::State",
      "severity" => "Filters::Chips::AgentInsights::Severity",
      "proposal_type" => "Filters::Chips::AgentInsights::ProposalType",
      "category" => "Filters::Chips::AgentInsights::Category",
      "confidence" => "Filters::Chips::AgentInsights::Confidence",
      "created_at" => "Filters::Chips::CreatedAt",
      "created_job_present" => "Filters::Chips::AgentInsights::CreatedJobPresent"
    }.freeze

    module_function

    def install_into(scope)
      scope.effect("agent insights filter subject") do
        Filters.register_subject(name: AgentInsights::SmartFolders::SUBJECT, model: AgentInsights::Suggestion, chips: CHIPS)
      end
    end
  end
end
