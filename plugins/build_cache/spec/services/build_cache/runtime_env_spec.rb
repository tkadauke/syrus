require "rails_helper"

RSpec.describe BuildCache::RuntimeEnv do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:workspace_path) { Pathname.new("/tmp/syrus-workflow-#{workflow.id}") }

  describe ".for" do
    it "always forwards a per-workflow SCCACHE_SERVER_PORT" do
      env = described_class.for(workflow: workflow, workspace_path: workspace_path)

      expect(env["SCCACHE_SERVER_PORT"]).to eq(BuildCache::DaemonAddress.port_for(workflow).to_s)
    end

    it "does not forward SCCACHE_BASEDIRS when the repository has not opted in" do
      env = described_class.for(workflow: workflow, workspace_path: workspace_path)

      expect(env).not_to have_key("SCCACHE_BASEDIRS")
    end

    it "forwards SCCACHE_BASEDIRS as the workspace path when the repository opted in" do
      BuildCache::RepositorySettings.create!(repository: job.repository, basedirs_safe: true)

      env = described_class.for(workflow: workflow, workspace_path: workspace_path)

      expect(env["SCCACHE_BASEDIRS"]).to eq(workspace_path.to_s)
    end

    it "does not forward SCCACHE_BASEDIRS when the repository explicitly opted out" do
      BuildCache::RepositorySettings.create!(repository: job.repository, basedirs_safe: false)

      env = described_class.for(workflow: workflow, workspace_path: workspace_path)

      expect(env).not_to have_key("SCCACHE_BASEDIRS")
    end
  end

  describe ".basedirs_safe?" do
    it "is false when the workflow's job has no repository settings row" do
      expect(described_class.basedirs_safe?(workflow)).to be false
    end
  end
end
