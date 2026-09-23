require "rails_helper"

RSpec.describe PrepareScope do
  describe ".for_workflow" do
    it "derives a workflow-namespaced scope from the workflow's job repository" do
      job = Factories.job
      workflow = job.workflows.first

      scope = described_class.for_workflow(workflow)

      expect(scope.namespace).to eq("workflow")
      expect(scope.id).to eq(workflow.id)
      expect(scope.repository).to eq(job.repository)
      expect(scope.cache_key).to eq("workflow:#{workflow.id}")
    end
  end

  describe ".for_chat_session" do
    it "derives a chat-namespaced scope from the given repository" do
      user = Factories.user
      repository = Factories.repository(user: user)
      chat_session = ChatSession.create!(user: user)

      scope = described_class.for_chat_session(chat_session, repository: repository)

      expect(scope.namespace).to eq("chat")
      expect(scope.id).to eq(chat_session.id)
      expect(scope.repository).to eq(repository)
      expect(scope.cache_key).to eq("chat:#{chat_session.id}")
    end
  end

  describe "#cache_key" do
    it "differs between a workflow scope and a chat scope that share the same numeric id" do
      workflow_scope = described_class.new(namespace: "workflow", id: 7, repository: nil)
      chat_scope = described_class.new(namespace: "chat", id: 7, repository: nil)

      expect(workflow_scope.cache_key).not_to eq(chat_scope.cache_key)
    end
  end
end
