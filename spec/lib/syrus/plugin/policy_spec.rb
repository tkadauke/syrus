require "rails_helper"

RSpec.describe Syrus::Plugin::Policy, :reset_plugin_registry do
  before { described_class.restore_definition! }

  let(:admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:member) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  before { RepositoryMembership.create!(repository: repository, user: member, role: "read") }

  def register_family_policy(name, capability, behavior)
    provider = Class.new do
      define_singleton_method(:key) { name }
      define_singleton_method(:display_name) { name }
      define_singleton_method(capability, &behavior)
    end
    constant = "#{name.camelize}Policy"
    stub_const(constant, provider)
    Syrus::PluginRegistry.register(name:, version: "1", provides: {}, family_provides: [
      Syrus::Plugin::FamilyDeclaration.build(family: :policy, provider: constant, provisional: [ capability ])
    ])
  end

  def restriction(origin, ids)
    Class.new do
      define_singleton_method(:origin_key) { origin }
      define_singleton_method(:visible_origin_ids) { |user:| ids }
    end
  end

  it "defines both capabilities as fail-closed collections with legacy mappings" do
    definition = Syrus::Plugin::Family.fetch(:policy)
    expect(definition.legacy_mappings.keys).to eq(described_class::CAPABILITY_FOR_LEGACY.keys)
    definition.capabilities.each_value do |capability|
      expect(capability).to have_attributes(composition: :collect, decline: nil, tier: :provisional)
      expect(capability.failure.call).to eq([ described_class::FAIL_CLOSED ])
    end
  end

  it "applies every restriction (explicit composition)" do
    a = Factories.job_record(repository: repository, origin: "first", origin_id: "1")
    b = Factories.job_record(repository: repository, origin: "first", origin_id: "2", issue_number: 2)
    c = Factories.job_record(repository: repository, origin: "second", origin_id: "1", issue_number: 3)
    d = Factories.job_record(repository: repository, origin: "second", origin_id: "2", issue_number: 4)
    ordinary = Factories.job_record(repository: repository, issue_number: 5)
    first = restriction("first", %w[1])
    second = restriction("second", %w[2])
    register_family_policy("first_policy", :job_visibility_restrictions, ->(_ctx) { first })
    register_family_policy("second_policy", :job_visibility_restrictions, ->(_ctx) { second })

    expect(Job.visible_to(member)).to contain_exactly(a, d, ordinary)
    expect(Job.visible_to(member)).not_to include(b, c)
  end

  it "fails closed when a Job visibility restriction provider errors: non-admins see nothing" do
    visible = Factories.job_record(repository: repository, origin: "healthy", origin_id: "1")
    ordinary = Factories.job_record(repository: repository, issue_number: 2)
    healthy = restriction("healthy", %w[1])
    register_family_policy("healthy_policy", :job_visibility_restrictions, ->(_ctx) { healthy })
    register_family_policy("broken_policy", :job_visibility_restrictions, ->(_ctx) { raise "restriction unavailable" })

    expect(Job.visible_to(member)).to be_empty
    expect(Job.visible_to(member)).not_to include(visible, ordinary)
  end

  it "fails closed when a restriction raises while it is being evaluated" do
    ordinary = Factories.job_record(repository: repository)
    exploding = Class.new do
      def self.origin_key = "explodes"
      def self.visible_origin_ids(user:) = raise("lookup failed")
    end
    register_family_policy("exploding_policy", :job_visibility_restrictions, ->(_ctx) { exploding })

    expect(Job.visible_to(member)).not_to include(ordinary)
    expect(Job.visible_to(member)).to be_empty
  end

  it "fails closed when a provider returns an invalid value" do
    ordinary = Factories.job_record(repository: repository)
    register_family_policy("invalid_policy", :job_visibility_restrictions, ->(_ctx) { "not a module" })

    expect(Job.visible_to(member)).not_to include(ordinary)
  end

  it "fails closed when the provider's circuit breaker is open" do
    ordinary = Factories.job_record(repository: repository)
    tripped = restriction("tripped", [])
    register_family_policy("tripped_policy", :job_visibility_restrictions, ->(_ctx) { tripped })
    allow(Syrus::PluginInvocation.runtime_health).to receive(:allow?).and_return(false)

    expect(Job.visible_to(member)).not_to include(ordinary)
  end

  it "keeps admin bypass even when a restriction provider fails" do
    ordinary = Factories.job_record(repository: repository)
    register_family_policy("broken_policy", :job_visibility_restrictions, ->(_ctx) { raise "restriction unavailable" })

    expect(Job.visible_to(admin, scope: Job.all)).to include(ordinary)
  end

  it "still raises for ambiguous restrictions on one origin" do
    one = restriction("dup", [])
    two = restriction("dup", [])
    register_family_policy("one_policy", :job_visibility_restrictions, ->(_ctx) { one })
    register_family_policy("two_policy", :job_visibility_restrictions, ->(_ctx) { two })

    expect { Job.visible_to(member).load }.to raise_error(JobVisibility::DuplicateRestriction)
  end

  it "adapts legacy job visibility and repository filter registrations" do
    legacy = restriction("legacy", [])
    legacy.include(Syrus::Plugin::JobVisibilityRestriction)
    Syrus::PluginRegistry.register(name: "legacy_policy", version: "1", provides: { job_visibility_restriction: legacy })
    expect(described_class.restrictions(:job_visibility_restrictions)).to include(legacy)
  end

  describe ".filter_repositories" do
    it "applies every filter in order" do
      other = Factories.repository(user: owner, owner: "acme", name: "other")
      narrow = Class.new { def self.apply(scope:, user:) = scope.where(name: "other") }
      register_family_policy("narrow_policy", :repository_filters, ->(_ctx) { narrow })

      expect(described_class.filter_repositories(Repository.accessible_to(owner), user: owner)).to contain_exactly(other)
    end

    it "fails closed when a repository filter provider errors" do
      repository
      register_family_policy("broken_filter", :repository_filters, ->(_ctx) { raise "filter unavailable" })

      expect(Repository.accessible_to(owner)).to include(repository)
      expect(described_class.filter_repositories(Repository.accessible_to(owner), user: owner)).to be_empty
    end

    it "fails closed when a filter raises while applying" do
      repository
      exploding = Class.new { def self.apply(scope:, user:) = raise("apply failed") }
      register_family_policy("exploding_filter", :repository_filters, ->(_ctx) { exploding })

      expect(described_class.filter_repositories(Repository.accessible_to(owner), user: owner)).to be_empty
    end
  end
end
