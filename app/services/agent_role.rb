module AgentRole
  # Chat surface roles
  CHAT_PLANNER    = "chat:planner"
  CHAT_ADMIN      = "chat:admin"
  CHAT_CODING     = "chat:coding"
  CHAT_LOCAL      = "chat:local"
  CHAT_WALKTHROUGH = "chat:walkthrough"
  CHAT_EVALUATOR  = "chat:evaluator"

  # Workflow/run surface roles
  WORKFLOW_IMPLEMENT                = "workflow:implement"
  WORKFLOW_REBASE_CONFLICT          = "workflow:rebase_conflict"
  WORKFLOW_SUMMARY_TEST_PLAN        = "workflow:summary_test_plan"
  WORKFLOW_ADVERSARIAL_REVIEWER     = "workflow:adversarial_reviewer"
  WORKFLOW_VISUAL_REVIEWER          = "workflow:visual_reviewer"
  WORKFLOW_MANUAL                   = "workflow:manual"

  # Infrastructure (future)
  INFRASTRUCTURE_MAIN_REPAIR = "infrastructure:main_repair"
  AGENT_INSIGHT               = "agent:insight"

  # Helper roles — produce no agentic turn, expose no tools
  HELPER_INGESTION     = "helper:ingestion"
  HELPER_PR_COMMENT    = "helper:pr_comment"
  HELPER_CHAT_TITLE    = "helper:chat_title"
  HELPER_DIRECT_TITLE  = "helper:direct_title"
  HELPER_PR_COPY       = "helper:pr_copy"
  HELPER_WALKTHROUGH   = "helper:walkthrough"

  WORKFLOW_ROLES = [
    WORKFLOW_IMPLEMENT,
    WORKFLOW_REBASE_CONFLICT,
    WORKFLOW_SUMMARY_TEST_PLAN,
    WORKFLOW_ADVERSARIAL_REVIEWER,
    WORKFLOW_VISUAL_REVIEWER,
    WORKFLOW_MANUAL
  ].freeze

  CHAT_ROLES = [
    CHAT_PLANNER,
    CHAT_ADMIN,
    CHAT_CODING,
    CHAT_LOCAL,
    CHAT_WALKTHROUGH,
    CHAT_EVALUATOR
  ].freeze

  HELPER_ROLES = [
    HELPER_INGESTION,
    HELPER_PR_COMMENT,
    HELPER_CHAT_TITLE,
    HELPER_DIRECT_TITLE,
    HELPER_PR_COPY,
    HELPER_WALKTHROUGH
  ].freeze

  ALL_ROLES = (WORKFLOW_ROLES + CHAT_ROLES + HELPER_ROLES + [
    INFRASTRUCTURE_MAIN_REPAIR,
    AGENT_INSIGHT
  ]).freeze
end
