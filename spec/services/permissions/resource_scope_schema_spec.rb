require "rails_helper"

RSpec.describe Permissions::ResourceScopeSchema do
  let(:context) { Struct.new(:visible_ids).new([ 1 ]) }
  let(:schema) do
    described_class.new(
      type: :repository,
      lookup: ->(identifier, context:) { { id: identifier.to_i, name: "Visible" } if context.visible_ids.include?(identifier.to_i) },
      normalize: ->(scope, context:) do
        raise ActiveRecord::RecordNotFound unless context.visible_ids.include?(scope.fetch(:repository_id).to_i)

        { paths: Array(scope[:paths]).map(&:to_s).uniq.sort, repository_id: scope.fetch(:repository_id).to_i }
      end,
      validate: ->(scope, context:) { scope["paths"].any?(&:blank?) ? [ "paths must not be blank" ] : [] },
      label: ->(scope, context:) { "Repository #{scope.fetch('repository_id')}" },
      compare: ->(left, right, context:) do
        if left == right
          :equal
        elsif left["repository_id"] == right["repository_id"] && (left["paths"] - right["paths"]).empty?
          :narrower
        else
          :disjoint
        end
      end
    )
  end

  it "does not distinguish unknown identifiers from resources hidden from the caller" do
    unknown = schema.lookup(99, context: context)
    hidden = schema.lookup(2, context: context)

    expect(unknown).to eq(hidden)
    expect(unknown.status).to eq(:not_found)
    expect(unknown).to be_fail_closed
  end

  it "returns visible resources without exposing lookup implementation details" do
    result = schema.lookup(1, context: context)

    expect(result).to be_success
    expect(result.value).to eq(id: 1, name: "Visible")
  end

  it "canonically normalizes JSON scope values before validation" do
    result = schema.normalize({ paths: [ "z", "a", "z" ], repository_id: "1" }, context: context)

    expect(result).to be_success
    expect(result.value).to eq("paths" => %w[a z], "repository_id" => 1)
    expect(result.value).to be_frozen
    expect(result.value["paths"]).to be_frozen
  end

  it "canonicalizes symbol values to their JSON string representation" do
    symbol = described_class.new(type: :account).normalize({ access: :read }, context: context)
    string = described_class.new(type: :account).normalize({ "access" => "read" }, context: context)

    expect(symbol).to be_success
    expect(symbol.value).to eq(string.value)
    expect(symbol.value["access"]).to be_frozen
  end

  it "returns explicit fail-closed outcomes for invalid and failed normalization" do
    invalid = schema.normalize({ paths: [ "" ], repository_id: 1 }, context: context)
    hidden = schema.normalize({ paths: [], repository_id: 2 }, context: context)
    malformed = schema.normalize({}, context: context)

    expect(invalid.status).to eq(:invalid)
    expect(invalid.errors).to eq([ "paths must not be blank" ])
    expect(hidden.status).to eq(:failed)
    expect(malformed.status).to eq(:failed)
    expect(hidden.errors).to be_empty
    expect(malformed.errors).to be_empty
  end

  it "rejects ambiguous keys and non-JSON values during canonicalization" do
    ambiguous = described_class.new(type: :account).normalize({ id: 1, "id" => 2 }, context: context)
    unsupported = described_class.new(type: :account).normalize({ id: Object.new }, context: context)

    non_json_numbers = [ Float::NAN, Float::INFINITY, -Float::INFINITY, Rational(1, 2) ].map do |value|
      described_class.new(type: :account).normalize({ amount: value }, context: context)
    end

    expect(ambiguous.status).to eq(:failed)
    expect(unsupported.status).to eq(:failed)
    expect(non_json_numbers).to all(have_attributes(status: :failed))
  end

  it "labels and compares only successfully normalized scopes" do
    label = schema.label({ repository_id: 1, paths: [] }, context: context)
    comparison = schema.compare(
      { repository_id: 1, paths: [ "app" ] },
      { repository_id: 1, paths: [ "app", "spec" ] },
      context: context
    )

    expect(label.value).to eq("Repository 1")
    expect(comparison.value).to eq(:narrower)
    expect(schema.label({ repository_id: 2 }, context: context)).to be_fail_closed
  end

  it "fails closed when provider hooks raise or return an unsupported comparison" do
    raising = described_class.new(type: :account, lookup: ->(*) { raise "backend detail" })
    invalid_comparison = described_class.new(type: :account, compare: ->(*) { :overlaps })

    expect(raising.lookup("secret", context: context)).to eq(described_class::Result.new(status: :failed))
    expect(invalid_comparison.compare({}, {}, context: context).status).to eq(:failed)
  end
end
