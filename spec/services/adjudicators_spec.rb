require "rails_helper"

RSpec.describe Adjudicators do
  def adjudicator(verdict, name: "test")
    Module.new do
      include Syrus::Plugin::Adjudicator

      class << self
        attr_accessor :verdict_to_return, :adjudicator_name
      end

      def self.adjudicate(problem:, **) = verdict_to_return
      def self.name = adjudicator_name
    end.tap do |mod|
      mod.verdict_to_return = verdict
      mod.adjudicator_name = name
    end
  end

  def register(mod)
    Syrus::PluginRegistry.register(name: "adjudicator_plugin", version: "1.0.0", provides: { adjudicator: mod })
  end

  it "returns the first decided verdict" do
    register(adjudicator(Adjudication.dismiss(reason: "plugin_said_so"), name: "plugin"))

    result = described_class.call(problem: Problem[:timeout])

    expect(result).to be_dismiss
    expect(result.reason).to eq("plugin_said_so")
  end

  it "reports every adjudicator it consulted when none decides" do
    result = described_class.call(problem: Problem[:timeout])

    expect(result).to be_inconclusive
    expect(result.evidence[:consulted]).to include("inherited_grader_failure", "validated_landing")
  end

  # Rung 0 runs on the failure path. A broken cheap check must not stop the
  # expensive rungs from getting their turn.
  it "treats a raising adjudicator as declining, loudly" do
    broken = adjudicator(nil, name: "broken")
    def broken.adjudicate(problem:, **) = raise("boom")
    register(broken)
    allow(Rails.logger).to receive(:warn)

    expect(described_class.call(problem: Problem[:timeout])).to be_inconclusive
    expect(Rails.logger).to have_received(:warn).with(/broken raised RuntimeError/)
  end
end
