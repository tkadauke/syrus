require "rails_helper"

RSpec.describe Achievements::Registry do
  def definition(**overrides)
    Achievements::Definition.build(**{
      key: "t.one", scope: :user, trigger: "job.landed", evaluator: "T::Eval",
      subject_kinds: %i[job], category: :work, rarity: :common
    }.merge(overrides))
  end

  def problems_for(*defs) = described_class.new(defs).problems

  it "ships a valid example catalog" do
    expect(described_class.default.problems).to eq([])
    expect(described_class.default.validate!).to be_a(described_class)
    expect(described_class.default.for_scope(:instance)).not_to be_empty
    expect(described_class.default.for_scope(:user)).not_to be_empty
  end

  it "fetches by key and raises for unknown keys" do
    registry = described_class.new([ definition ])
    expect(registry.fetch("t.one").version).to eq(1)
    expect { registry.fetch("nope") }.to raise_error(KeyError)
  end

  it "reports duplicate keys" do
    expect(problems_for(definition, definition)).to include("t.one: duplicate key")
  end

  it "rejects invalid scope/subject combinations" do
    expect(problems_for(definition(scope: :instance, subject_kinds: %i[user])).join).to include("instance scope cannot use subject kind user")
    expect(problems_for(definition(scope: :user, subject_kinds: %i[installation])).join).to include("user scope cannot use subject kind installation")
  end

  it "rejects unknown scopes, categories, rarities, visibilities, and subject kinds" do
    joined = problems_for(definition(scope: :team, category: :x, rarity: :y, visibility: :z, subject_kinds: %i[bogus])).join("\n")
    expect(joined).to include("scope must be", "category must be", "rarity must be", "visibility must be", "unknown subject kinds bogus")
  end

  it "rejects empty subject kinds, bad keys, versions and identities" do
    joined = problems_for(definition(key: "Bad Key", version: 0, trigger: "bad trigger", subject_kinds: [])).join("\n")
    expect(joined).to include("subject_kinds must not be empty", "key must be", "version must be", "trigger must be")
  end

  it "rejects incompatible presentation metadata" do
    expect(problems_for(definition(visibility: :hidden, presentation: { teaser_key: "x" })).join).to include("hidden achievements cannot carry a teaser_key")
    expect(problems_for(definition(presentation: { bogus: "x" })).join).to include("unknown presentation keys bogus")
    expect(problems_for(definition(presentation: { title_key: "a" * 201 })).join).to include("presentation values must be strings")
  end

  it "raises InvalidRegistry from validate! with the problem list" do
    expect { described_class.new([ definition, definition ]).validate! }
      .to raise_error(described_class::InvalidRegistry) { |error| expect(error.problems).to be_present }
  end
end
