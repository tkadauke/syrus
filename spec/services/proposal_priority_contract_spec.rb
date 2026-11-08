require "rails_helper"

# Contract: Job priority is an operator-only decision. Wording changes must
# not silently drop this constraint from the prompt or either proposal tool.
RSpec.describe "proposal priority operator-only contract" do
  def squish(text) = text.to_s.gsub(/\s+/, " ")

  shared_examples "an operator-only priority rule" do
    it "states the rule and instructs omission" do
      text = squish(rule_text)
      expect(text).to match(/operator-only scheduling decision/i)
      expect(text).to include("urgent")
      expect(text).to match(/explicitly specif/i)
      expect(text).to match(/severity/i)
      expect(text).to match(/omit/i)
      expect(text).not_to match(/Set (jobs\[\]\.)?priority to/i)
    end
  end

  describe Mcp::Tools::ProposeJobTool do
    let(:schema_text) { described_class.input_schema.to_h.dig(:properties, :priority, :description) }

    it_behaves_like "an operator-only priority rule" do
      let(:rule_text) { described_class.description }
    end

    it_behaves_like "an operator-only priority rule" do
      let(:rule_text) { schema_text }
    end
  end

  describe Mcp::Tools::ProposeEpicWithJobsTool do
    let(:schema_text) do
      described_class.input_schema.to_h.dig(:properties, :jobs, :items, :properties, :priority, :description)
    end

    it_behaves_like "an operator-only priority rule" do
      let(:rule_text) { described_class.description }
    end

    it_behaves_like "an operator-only priority rule" do
      let(:rule_text) { schema_text }
    end

    it "forbids inferring relative priorities among children" do
      expect(squish(described_class.description)).to match(/infer relative priorities among children/)
      expect(squish(schema_text)).to match(/relative ordering among children/)
    end
  end

  describe Prompts::ChatSystem do
    it "states that priority is operator-only" do
      out = squish(described_class.new(repository: repository(owner: "acme", name: "widgets")).to_s)
      expect(out).to include("Job priority is an operator-only scheduling decision")
      expect(out).to include("`jobs[].priority`")
      expect(out).to match(/Severity, production impact, recency, incident status/)
      expect(out).to match(/Otherwise omit the field and accept the system default/)
    end
  end
end
