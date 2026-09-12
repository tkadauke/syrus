module AgentActivity
  class SessionContext
    REGISTRY = {
      "Run" => "AgentActivity::RunSessionContext",
      "ChatSession" => "AgentActivity::ChatSessionContext",
      "DesignDocs::DesignDocAgentRun" => "AgentActivity::DesignDocSessionContext"
    }.freeze

    def self.for(agent)
      class_name = REGISTRY.fetch(agent.resumable_type, "AgentActivity::UnknownSessionContext")
      class_name.constantize.new(agent.resumable)
    end

    def initialize(resumable)
      @resumable = resumable
    end

    def kind = nil
    def role = nil
    def role_label = "Agent"
    def agent_provider = nil
    def state = nil
    def outcome_summary = nil
    def outcome_verdict = nil
    def job_payload = nil
    def repository_payload = nil
    def workflow_id = nil
    def trigger_kind = nil
    def transcript_path(scope:) = nil
    def chat_path = nil
  end
end
