require "rails_helper"

RSpec.describe Mcp::Tools::SubmitSummaryTool do
  let(:run) { Factories.job.initial_run }

  def call(pr_title: "Add greeting helper", pr_body: "Adds a tiny greet helper.", summary: "Implemented greet.")
    described_class.call(
      pr_title: pr_title, pr_body: pr_body, summary: summary,
      server_context: { run: run }
    )
  end

  describe "happy path" do
    it "accepts a run_id-only sidecar context" do
      described_class.call(
        pr_title: "Add greet",
        pr_body: "Adds it.",
        summary: "Done.",
        server_context: { run_id: run.id }
      )

      expect(run.reload.agent_pr_title).to eq("Add greet")
    end

    it "verifies the database connection before touching the Run" do
      verified = false
      allow(ActiveRecord::Base.connection).to receive(:verify!) { verified = true }

      call(pr_title: "Add greet")

      expect(verified).to be(true)
    end

    it "persists all three fields on the Run" do
      call(pr_title: "Add greet", pr_body: "Adds it.", summary: "Done.")
      expect(run.reload).to have_attributes(
        agent_pr_title: "Add greet",
        agent_pr_body:  "Adds it.",
        agent_summary:  "Done."
      )
    end

    it "strips leading/trailing whitespace from each field" do
      call(pr_title: "  Add greet  ", pr_body: "\nAdds it.\n", summary: " Done. ")
      expect(run.reload).to have_attributes(
        agent_pr_title: "Add greet",
        agent_pr_body:  "Adds it.",
        agent_summary:  "Done."
      )
    end

    it "normalizes binary-tagged UTF-8 fields before persisting" do
      call(
        pr_title: "Add ● summary".b,
        pr_body: "Preserve ● body.".b,
        summary: "Stored ● summary.".b
      )

      expect(run.reload).to have_attributes(
        agent_pr_title: "Add ● summary",
        agent_pr_body: "Preserve ● body.",
        agent_summary: "Stored ● summary."
      )
      expect(run.agent_pr_title.encoding).to eq(Encoding::UTF_8)
    end

    it "writes a JobLog audit line so the operator sees the call in the transcript" do
      expect { call(pr_title: "Add greet") }.to change { run.job_logs.count }.by(1)
      expect(run.job_logs.last.chunk).to include("[mcp] submit_summary received")
      expect(run.job_logs.last.chunk).to include("Add greet")
    end

    it "returns a non-error MCP::Tool::Response" do
      response = call
      expect(response).to be_a(MCP::Tool::Response)
      expect(response).not_to be_error
      expect(response.content.first[:text]).to eq("Saved.")
    end

    it "returns a tool error instead of raising when the sidecar hits an unexpected exception" do
      allow(Mcp::Tools).to receive(:write_log).and_raise(ActiveRecord::ConnectionNotEstablished, "server closed")

      response = nil
      expect { response = call(pr_title: "Add greet") }.not_to raise_error

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::ConnectionNotEstablished")
    end
  end

  describe "validation" do
    it "rejects empty pr_title" do
      response = call(pr_title: "   ")
      expect(response).to be_error
      expect(response.content.first[:text]).to match(/pr_title is required/)
      expect(run.reload.agent_pr_title).to be_nil
    end

    it "rejects pr_title over 120 chars" do
      response = call(pr_title: "A" * 121)
      expect(response).to be_error
      expect(response.content.first[:text]).to match(/pr_title too long/)
    end

    it "rejects empty pr_body" do
      response = call(pr_body: "")
      expect(response).to be_error
      expect(response.content.first[:text]).to match(/pr_body is required/)
    end

    it "rejects empty summary" do
      response = call(summary: "")
      expect(response).to be_error
      expect(response.content.first[:text]).to match(/summary is required/)
    end

    it "leaves the Run unchanged on a validation failure" do
      run.update!(agent_pr_title: "old", agent_pr_body: "old", agent_summary: "old")
      call(pr_title: "")
      expect(run.reload).to have_attributes(
        agent_pr_title: "old", agent_pr_body: "old", agent_summary: "old"
      )
    end
  end

  describe "schema surface" do
    it "exposes the tool name as `submit_summary` so claude lists it as mcp__syrus__submit_summary" do
      expect(described_class.tool_name).to eq("submit_summary")
    end

    it "describes the tool without directing the agent to invoke it" do
      description = described_class.description_value

      expect(description).to include("Stores a PR title, PR body, and operator-facing summary")
      expect(description).to include("implement and respond steps do not require it")
      [
        "Call this",
        "call this",
        "always call",
        "near the end of every run",
        "when you finish",
        "must call",
        "required to call"
      ].each do |directive|
        expect(description).not_to include(directive)
      end
    end

    it "marks all three fields as required" do
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to match_array(%w[pr_title pr_body summary])
    end
  end
end
