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
  end

  describe "#loop?" do
    it "returns true" do
      loop = described_class.new(max_iterations: 5, steps: [ :implement ])

      expect(loop.loop?).to be(true)
    end
  end

  describe "review_first" do
    it "defaults to false" do
      loop = described_class.new(max_iterations: 5, steps: [ :implement, :adversarial_review ])

      expect(loop.review_first?).to be(false)
    end

    it "requires exactly two steps" do
      expect {
        described_class.new(max_iterations: 5, steps: [ :implement ], review_first: true)
      }.to raise_error(ArgumentError, "review_first loop requires exactly 2 steps: [agent_step, review_step]")
    end
  end

  describe "#step_kinds" do
    it "returns the full step list when review_first is false" do
      loop = described_class.new(max_iterations: 5, steps: [ :implement, :adversarial_review ])

      expect(loop.step_kinds).to eq(%w[ implement adversarial_review ])
    end

    it "returns only the review step when review_first is true" do
      loop = described_class.new(max_iterations: 5, steps: [ :implement, :adversarial_review ], review_first: true)

      expect(loop.step_kinds).to eq(%w[ adversarial_review ])
    end
  end

  describe "#to_chain_template" do
    it "always serializes the full step pair, plus review_first" do
      loop = described_class.new(max_iterations: 3, steps: [ :implement, :adversarial_review ], review_first: true)

      expect(loop.to_chain_template).to eq(
        "type" => "loop",
        "max_iterations" => 3,
        "steps" => %w[ implement adversarial_review ],
        "review_first" => true
      )
    end

    it "defaults review_first to false in the serialized template" do
      loop = described_class.new(max_iterations: 3, steps: [ :implement, :grade ])

      expect(loop.to_chain_template).to eq(
        "type" => "loop",
        "max_iterations" => 3,
        "steps" => %w[ implement grade ],
        "review_first" => false
      )
    end
  end
end
