require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Syrus::Plugin::FamilyContractKit do
  ContractContext = Data.define(:decline)

  let(:provider) do
    Class.new do
      def self.key = :fixture
      def self.display_name = "Fixture"
      def self.items(context) = context.decline ? [] : [ "item" ]
    end
  end

  before do
    Syrus::Plugin::Family.reset!
    Syrus::Plugin::Family.define(:contract_fixture) do
      shape :facet
      capability :items, composition: :collect, absent: [], tier: :provisional,
        context: ContractContext, returns: Array
    end
  end

  after { Syrus::Plugin::Family.reset! }

  def validate(candidate = provider, contexts: { items: ContractContext.new(decline: false) },
    decline_contexts: { items: ContractContext.new(decline: true) })
    declaration = Syrus::Plugin::FamilyDeclaration.build(
      family: :contract_fixture, provider: "ContractFixture::Provider", provisional: %i[items]
    )
    described_class.validate!(declaration:, provider: candidate,
      contexts:, decline_contexts:)
  end

  it "accepts a conforming provider and installs the generated shared example" do
    expect { validate }.not_to raise_error
    Syrus::Plugin::TestKit::SharedExamples.install!
    registry = RSpec.world.shared_example_group_registry
    expect(registry.find([ :main ], "a valid contract_fixture provider")).to be_present
  end

  it "reports each family contract violation clearly" do
    expect { validate(Class.new) }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /required contract_fixture core method key/)

    wrong_signature = Class.new do
      def self.key = :fixture
      def self.display_name = "Fixture"
      def self.items = []
    end
    expect { validate(wrong_signature) }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /callable with 1 required/)

    wrong_return = Class.new do
      def self.key = :fixture
      def self.display_name = "Fixture"
      def self.items(_context) = "not an array"
    end
    expect { validate(wrong_return) }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /must return Array/)

    never_declines = Class.new do
      def self.key = :fixture
      def self.display_name = "Fixture"
      def self.items(_context) = [ "always" ]
    end
    expect { validate(never_declines) }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /must decline with \[\]/)

    expect { validate(contexts: {}) }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /missing call context/)
  end

  it "derives the complete capability set from the declaration" do
    Syrus::Plugin::Family.define(:multi_capability_fixture) do
      shape :facet
      capability :first, composition: :collect, absent: [], tier: :provisional,
        context: ContractContext, returns: Array
      capability :second, composition: :collect, absent: [], tier: :provisional,
        context: ContractContext, returns: Array
    end
    declaration = Syrus::Plugin::FamilyDeclaration.build(
      family: :multi_capability_fixture, provider: "ContractFixture::Provider", provisional: %i[first second]
    )

    expect do
      described_class.validate!(declaration:, provider:, contexts: {}, decline_contexts: {})
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /must define capability first/)
  end
end
