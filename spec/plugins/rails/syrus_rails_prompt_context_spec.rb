require "rails_helper"

RSpec.describe SyrusRails::PromptContext do
  let(:context)    { described_class.new }
  let(:repository) { double("repository") }
  let(:job)        { double("job") }

  describe "#call" do
    subject(:result) { context.call(repository: repository, job: job) }

    it "returns a non-empty string" do
      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end

    it "mentions the Rails-specific MCP tools" do
      expect(result).to include("read_schema")
      expect(result).to include("explain_migration")
      expect(result).to include("list_routes")
    end

    it "instructs the agent to call submit_artifact when db/schema.rb changes" do
      expect(result).to include("submit_artifact")
      expect(result).to include("rails_schema_erd")
    end

    it "instructs the agent to call submit_artifact for migration changes" do
      expect(result).to include("rails_migration_diff")
    end

    it "includes Syrus::Plugin::PromptInjector interface" do
      expect(described_class.ancestors).to include(Syrus::Plugin::PromptInjector)
    end
  end
end
