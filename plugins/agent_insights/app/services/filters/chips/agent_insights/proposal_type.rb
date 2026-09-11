module Filters
  module Chips
    module AgentInsights
      class ProposalType < EnumColumn
        filter_name "proposal_type"
        label "Proposal type"
        column :proposal_type
        values ::AgentInsights::Suggestion::PROPOSAL_TYPES
      end
    end
  end
end
