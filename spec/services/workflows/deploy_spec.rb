require "rails_helper"

RSpec.describe Workflows::Deploy do
  let(:job) { Factories.job }

  it "declares trigger_kind deploy" do
    expect(described_class.trigger_kind).to eq("deploy")
  end

  describe ".steps_for" do
    it "chains prepare then deploy" do
      expect(described_class.steps_for(job)).to eq(%w[prepare deploy])
    end
  end

  describe ".instantiate" do
    it "materializes the prepare -> deploy chain template" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.trigger_kind).to eq("deploy")
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare deploy])
      expect(workflow.chain_template).to eq([
        { "type" => "step", "kind" => "prepare" },
        { "type" => "step", "kind" => "deploy" }
      ])
    end

    it "omits prepare when the job has a prepare_skip_reason" do
      allow(job).to receive(:prepare_skip_reason).and_return("syrus-skip-prepare label")

      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[deploy])
    end
  end
end
