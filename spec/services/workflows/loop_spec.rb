require "rails_helper"

RSpec.describe Workflows::Loop do
  describe "#initialize" do
    it "stores the max iterations and stringifies step names" do
      loop = described_class.new(max_iterations: 5, steps: [ :implement, :grade ])

      expect(loop.max_iterations).to eq(5)
      expect(loop.steps).to eq(%w[ implement grade ])
    end

    it "rejects empty steps" do
      expect { described_class.new(max_iterations: 5, steps: []) }
        .to raise_error(ArgumentError, "loop steps required")
    end

    it "requires exactly two steps" do
      expect { described_class.new(max_iterations: 5, steps: [ :implement ]) }
        .to raise_error(ArgumentError, "loop requires exactly 2 steps: [agent_step, review_step]")
    end

    it "rejects more than two steps" do
      expect { described_class.new(max_iterations: 5, steps: [ :implement, :adversarial_review, :grade ]) }
        .to raise_error(ArgumentError, "loop requires exactly 2 steps: [agent_step, review_step]")
    end
  end

  describe "#loop?" do
    it "returns true" do
      loop = described_class.new(max_iterations: 5, steps: [ :implement, :adversarial_review ])

      expect(loop.loop?).to be(true)
    end
  end

  describe "#step_kinds" do
    it "returns only the review step (the last of the pair) for iteration 1" do
      loop = described_class.new(max_iterations: 5, steps: [ :implement, :adversarial_review ])

      expect(loop.step_kinds).to eq(%w[ adversarial_review ])
    end
  end

  describe "#to_chain_template" do
    it "serializes the full step pair with no review_first flag" do
      loop = described_class.new(max_iterations: 3, steps: [ :implement, :adversarial_review ])

      expect(loop.to_chain_template).to eq(
        "type" => "loop",
        "max_iterations" => 3,
        "steps" => %w[ implement adversarial_review ]
      )
    end
  end
end
