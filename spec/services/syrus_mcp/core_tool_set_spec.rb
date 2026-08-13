require "rails_helper"

RSpec.describe SyrusMcp::CoreToolSet do
  let(:run) { Factories.job.initial_run }

  describe ".available_for?" do
    it "returns true for any repository" do
      expect(described_class.available_for?(run.job.repository)).to be(true)
    end

    it "returns true for nil (direct/cron jobs without a repository context)" do
      expect(described_class.available_for?(nil)).to be(true)
    end
  end

  describe ".tool_definitions" do
    subject(:definitions) { described_class.tool_definitions }

    it "returns one definition per tool class in MCP_TOOL_CLASSES" do
      expect(definitions.size).to eq(described_class::MCP_TOOL_CLASSES.size)
    end

    it "includes all built-in workflow tool names" do
      names = definitions.map { |d| d[:name] }
      expect(names).to contain_exactly(
        "read_live_state",
        "read_memory", "write_memory", "delete_memory", "search_memories", "list_memories",
        "get_coverage_report", "read_run_worker_health",
        "start_preview", "stop_preview", "read_preview_log",
        "report_main_concern",
        "submit_summary", "submit_test_plan", "submit_artifact", "submit_visual_artifact", "submit_job_metadata", "submit_adversarial_review",
        "submit_insight", "update_insight", "list_insights", "read_insight",
        "list_recent_workflows", "read_run_transcript"
      )
    end

    it "includes a non-blank description for every tool" do
      definitions.each do |defn|
        expect(defn[:description]).to be_present, "#{defn[:name]} has no description"
      end
    end

    it "includes a hash input_schema for every tool" do
      definitions.each do |defn|
        expect(defn[:input_schema]).to be_a(Hash), "#{defn[:name]} missing input_schema hash"
      end
    end
  end

  describe "#handle" do
    subject(:tool_set) { described_class.new }

    it "delegates submit_summary to SubmitSummaryTool and persists the run fields" do
      context = { run_id: run.id }

      result = tool_set.handle("submit_summary", {
        pr_title: "Add greeting helper",
        pr_body:  "Adds a small helper.",
        summary:  "Wrote the helper."
      }, context)

      expect(result).not_to be_error
      expect(run.reload).to have_attributes(
        agent_pr_title: "Add greeting helper",
        agent_summary:  "Wrote the helper."
      )
    end

    it "delegates submit_test_plan and persists on the Workflow" do
      context = { run_id: run.id }

      result = tool_set.handle("submit_test_plan", {
        steps: [ "Run bin/rspec spec/" ]
      }, context)

      expect(result).not_to be_error
      expect(run.workflow.reload.artifact("test_plan")).to include("steps" => [ "Run bin/rspec spec/" ])
    end

    it "delegates read_live_state and returns a JSON payload" do
      context = { run_id: run.id }

      result = tool_set.handle("read_live_state", {}, context)

      expect(result).not_to be_error
      payload = JSON.parse(result.content.first[:text])
      expect(payload.dig("job", "id")).to eq(run.job_id)
    end

    it "raises for an unrecognized tool name" do
      expect {
        tool_set.handle("nonexistent_tool", {}, { run_id: run.id })
      }.to raise_error(/unknown tool/)
    end
  end
end
