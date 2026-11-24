module Syrus
  module Host
    # Read-only mirror of the agent role identifiers plugins may reference.
    # Values are copied from AgentRole, so plugins compare against the same
    # strings the host's authorization and tool-exposure code uses.
    module AgentRoles
      CHAT_PLANNER = AgentRole::CHAT_PLANNER
      COWORKER_CHAT = AgentRole::COWORKER_CHAT
      COWORKER = AgentRole::COWORKER
      AGENT_INSIGHT = AgentRole::AGENT_INSIGHT
      WORKFLOW_SUMMARY_TEST_PLAN = AgentRole::WORKFLOW_SUMMARY_TEST_PLAN
      WORKFLOW_COWORKER_REVIEWER = AgentRole::WORKFLOW_COWORKER_REVIEWER
      WORKFLOW_MANUAL = AgentRole::WORKFLOW_MANUAL
      WORKFLOW_ROLES = AgentRole::WORKFLOW_ROLES
    end
  end
end
