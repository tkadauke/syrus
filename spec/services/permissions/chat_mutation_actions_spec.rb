require "rails_helper"

RSpec.describe Permissions::ChatMutationActions do
  let(:entries) do
    McpToolRegistry.entries(surface: :chat).select do |entry|
      described_class.tool_names.include?(entry.tool_name)
    end.index_by(&:tool_name)
  end

  it "explicitly describes the complete remaining core chat mutation inventory" do
    expect(entries.keys).to contain_exactly(*described_class.tool_names)
    expect(entries.values).to all(
      have_attributes(mutation: true, explicit_descriptor: true)
    )
  end

  it "classifies operations from their real effects and risk" do
    expect(entries.fetch("propose_job").descriptor).to have_attributes(
      capability: "syrus.proposals@v1", effects: %i[internal_write], risk: :medium
    )
    expect(entries.fetch("reset_workspace").descriptor).to have_attributes(
      effects: %i[internal_write destructive], risk: :high
    )
    expect(entries.fetch("runtime_input").descriptor).to have_attributes(
      effects: %i[internal_write isolated_execution operational], risk: :high
    )
    expect(entries.fetch("delegate_issue").descriptor).to have_attributes(
      effects: %i[credential_use external_write operational], risk: :high
    )
  end

  it "marks every supported proposal entry point as its own approval effect" do
    expect(entries.values_at("propose_job", "propose_epic_with_jobs")).to all(
      have_attributes(approval_effect: true)
    )
    expect(McpToolRegistry.entries(surface: :chat).map(&:tool_name)).not_to include("propose_epic")
  end

  it "preserves the legacy per-invocation authority and default policies" do
    entries.each_value do |entry|
      expect(entry.descriptor).to have_attributes(
        maximum_autonomy: :invocation,
        authority_durations: %i[invocation]
      )
    end

    allowed = %w[
      propose_job propose_epic_with_jobs
      withdraw_pending_action set_bookmark rename_chat pin_chat unpin_chat
      suggest_next_step ask_user_question mark_goal_completed mark_goal_blocked
      update_pinned_context remove_pinned_context
    ]
    allowed.each { |name| expect(entries.fetch(name).descriptor.defaults.values.uniq).to eq([ :allow ]) }
    (described_class.tool_names - allowed).each do |name|
      expect(entries.fetch(name).descriptor.defaults.values.uniq).to eq([ :ask ])
    end
  end

  it "preserves role and feature restrictions on control tools" do
    expect(entries.fetch("reset_workspace")).to have_attributes(
      feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ]
    )
    expect(entries.fetch("complete_implement_step")).to have_attributes(
      required_roles: [ AgentRole::CHAT_CODING, AgentRole::CHAT_LOCAL ]
    )
    expect(entries.fetch("open_in_local_mode")).to have_attributes(
      feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]
    )
  end

  it "normalizes fingerprints and redacts secrets" do
    descriptor = entries.fetch("runtime_start").descriptor
    arguments = { options: { token: "secret", port: 3000 }, provider: "browser" }

    expect(descriptor.normalize_fingerprint(arguments)).to eq(
      "options" => { "port" => 3000, "token" => "secret" }, "provider" => "browser"
    )
    expect(descriptor.redact(arguments)).to eq(
      "options" => { "port" => 3000, "token" => "[REDACTED]" }, "provider" => "browser"
    )
  end
end
