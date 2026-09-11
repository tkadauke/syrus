module Filters
  module Chips
    module AgentInsights
      class ProposalType < EnumColumn
        filter_name "proposal_type"
        label "Proposal type"
        column :proposal_type
        values "create_job", "save_memory", "remove_memory", "revise_existing_insight", "informational"
      end
    end
  end
end
