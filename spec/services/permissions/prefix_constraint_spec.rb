require "rails_helper"

# A `string_prefix` constraint lets one rule stand for a family of invocations
# -- "every `git commit ...`" -- instead of a single exact one. Two properties
# make that safe to offer, and both are load-bearing:
#
#   * matching compares tokens, not raw text, so `git commitfoo` does not
#     satisfy a `git commit` rule; and
#   * a descriptor only projects a prefix-matchable value for an argument it
#     has established is safe to widen, so a command carrying shell syntax is
#     not projected at all and there is nothing for a rule to match.
#
# Raw-string matching plus either guard alone is not enough: the tokens of
# `git commit -m x; rm -rf /` *do* begin with git, commit.
RSpec.describe "string_prefix constraints" do
  def build_descriptor(constraint_fields:)
    Permissions::CapabilityDescriptor.new(
      capability: "demo.run@v1", operation: "demo.run/exec@v1",
      effects: %i[local_read], risk: :low,
      requestable_roles: [ AgentRole::CHAT_PLANNER ],
      defaults: { AgentRole::CHAT_PLANNER => :ask },
      maximum_autonomy: :permanent,
      authority_durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
      resource_scope: { type: :none },
      classifier: ->(_arguments) { { operation: "demo.run/exec@v1", effects: %i[local_read], confidence: :certain } },
      constraint_fields:,
      fingerprint_normalizer: ->(arguments) {
        source = arguments.to_h.symbolize_keys
        { "command_prefix" => source[:command], "exact" => source[:exact] }.compact
      },
      redactor: ->(arguments) { arguments }
    )
  end

  let(:descriptor) { build_descriptor(constraint_fields: { command_prefix: :string_prefix, exact: :string }) }
  let(:invocation) { Struct.new(:capability, :operation, :resource_scope).new("demo.run@v1", "demo.run/exec@v1", {}) }

  def rule(constraints)
    Permissions::PolicyRule.new(id: "r", layer: "agent", policy: "allow", source: "spec",
      capability: "demo.run@v1", operation: "demo.run/exec@v1", resource_scope: nil,
      constraints:, selectors: {}, delegable: false, rationale: "spec")
  end

  def status(constraints, arguments)
    rule(constraints).match_status(invocation, descriptor:, context: {}, arguments: arguments.stringify_keys)
  end

  it "matches a leading run of whole tokens" do
    expect(status({ "command_prefix" => "git commit" }, { "command_prefix" => "git commit -m hello" })).to eq(:match)
    expect(status({ "command_prefix" => "git commit" }, { "command_prefix" => "git commit" })).to eq(:match)
  end

  it "does not match a longer token that merely starts with the same text" do
    expect(status({ "command_prefix" => "git commit" }, { "command_prefix" => "git commitfoo --bare" })).to eq(:no_match)
  end

  it "does not match a different command under the same executable" do
    expect(status({ "command_prefix" => "git commit" }, { "command_prefix" => "git push --force" })).to eq(:no_match)
  end

  it "does not match when the descriptor projected nothing to match against" do
    expect(status({ "command_prefix" => "git commit" }, {})).to eq(:no_match)
  end

  it "refuses an empty prefix rather than treating it as matching everything" do
    expect(status({ "command_prefix" => "" }, { "command_prefix" => "git commit -m x" })).to eq(:no_match)
    expect(status({ "command_prefix" => "   " }, { "command_prefix" => "git commit -m x" })).to eq(:no_match)
  end

  it "still compares an ordinary string constraint for equality" do
    expect(status({ "exact" => "abc" }, { "exact" => "abc" })).to eq(:match)
    expect(status({ "exact" => "abc" }, { "exact" => "abcdef" })).to eq(:no_match)
  end

  it "keeps a prefix projection out of the invocation's identity" do
    # Identity is what distinguishes one invocation from another. A widening
    # projection is an input to matching only -- hashing it would change every
    # fingerprint already issued for a descriptor that later gains a prefix
    # field, invalidating approvals that were granted in good faith.
    with_prefix = Permissions::InvocationFingerprint.call(descriptor:, arguments: { command: "git commit -m a", exact: "x" })
    other_prefix = Permissions::InvocationFingerprint.call(descriptor:, arguments: { command: "git push", exact: "x" })

    expect(with_prefix).to eq(other_prefix)
  end

  it "rejects a constraint field type it does not know" do
    expect { build_descriptor(constraint_fields: { command_prefix: :regexp }) }
      .to raise_error(ArgumentError, /unknown constraint field types/)
  end
end
