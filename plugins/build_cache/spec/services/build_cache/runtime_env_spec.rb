require "rails_helper"

RSpec.describe BuildCache::RuntimeEnv do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:workspace_path) { Pathname.new("/tmp/syrus-workflow-#{workflow.id}") }
  let(:workflow_scope) { PrepareScope.for_workflow(workflow) }

  describe ".for" do
    it "always forwards a per-scope SCCACHE_SERVER_PORT" do
      env = described_class.for(scope: workflow_scope, workspace_path: workspace_path)

      expect(env["SCCACHE_SERVER_PORT"]).to eq(BuildCache::DaemonAddress.port_for(workflow_scope).to_s)
    end

    it "does not forward SCCACHE_BASEDIRS when the repository has not opted in" do
      env = described_class.for(scope: workflow_scope, workspace_path: workspace_path)

      expect(env).not_to have_key("SCCACHE_BASEDIRS")
    end

    it "forwards SCCACHE_BASEDIRS as the workspace path when the repository opted in" do
      BuildCache::RepositorySettings.create!(repository: job.repository, basedirs_safe: true)

      env = described_class.for(scope: workflow_scope, workspace_path: workspace_path)

      expect(env["SCCACHE_BASEDIRS"]).to eq(workspace_path.to_s)
    end

    it "does not forward SCCACHE_BASEDIRS when the repository explicitly opted out" do
      BuildCache::RepositorySettings.create!(repository: job.repository, basedirs_safe: false)

      env = described_class.for(scope: workflow_scope, workspace_path: workspace_path)

      expect(env).not_to have_key("SCCACHE_BASEDIRS")
    end

    it "computes a distinct SCCACHE_SERVER_PORT for a chat-session scope on the same repository" do
      chat_session = ChatSession.create!(user: job.user)
      chat_scope = PrepareScope.for_chat_session(chat_session, repository: job.repository)

      workflow_env = described_class.for(scope: workflow_scope, workspace_path: workspace_path)
      chat_env = described_class.for(scope: chat_scope, workspace_path: workspace_path)

      expect(chat_env["SCCACHE_SERVER_PORT"]).not_to eq(workflow_env["SCCACHE_SERVER_PORT"])
    end

    it "forwards SCCACHE_BASEDIRS for a chat-session scope when the repository opted in" do
      BuildCache::RepositorySettings.create!(repository: job.repository, basedirs_safe: true)
      chat_session = ChatSession.create!(user: job.user)
      chat_scope = PrepareScope.for_chat_session(chat_session, repository: job.repository)

      env = described_class.for(scope: chat_scope, workspace_path: workspace_path)

      expect(env["SCCACHE_BASEDIRS"]).to eq(workspace_path.to_s)
    end
  end

  describe ".basedirs_safe?" do
    it "is false when the scope's repository has no repository settings row" do
      expect(described_class.basedirs_safe?(workflow_scope)).to be false
    end

    it "is false when the scope has no repository" do
      scope = PrepareScope.new(namespace: "chat", id: 1, repository: nil)

      expect(described_class.basedirs_safe?(scope)).to be false
    end
  end
end
