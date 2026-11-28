# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RSpec suite configuration" do
  it "runs examples in reproducible random order" do
    expect(RSpec.configuration.seed_used?).to be(true)
    expect(RSpec.configuration.ordering_registry.fetch(:global))
      .to be_a(RSpec::Core::Ordering::Random)
  end
end
