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
end
