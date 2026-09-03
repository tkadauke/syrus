require "rails_helper"

# The point of installing kinds rather than merging them on every read: a
# disabled plugin's kinds are *removed*, not merely filtered out downstream by
# whichever cache happens to notice.
RSpec.describe Syrus::KindRegistry, "install and teardown" do
  def set_enabled(enabled)
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: enabled, disableable: true)
  end

  it "adds a plugin's kinds while it is enabled and takes them back when it is not" do
    set_enabled(true)
    expect(Job::Kind.values).to include("agent_insight")
    expect(Workflow::TriggerKind.values).to include("agent_insight")
    expect(Step::Kind.values).to include("agent_insight_run")

    set_enabled(false)

    expect(Job::Kind.values).not_to include("agent_insight")
    expect(Workflow::TriggerKind.values).not_to include("agent_insight")
    expect(Step::Kind.values).not_to include("agent_insight_run")
  end

  it "does not accumulate duplicates across repeated syncs" do
    set_enabled(true)
    5.times { Syrus::PluginRegistry.bump_generation!; Job::Kind.values }

    expect(Job::Kind.values.count("agent_insight")).to eq(1)
  end

  it "leaves core's own kinds untouched by a plugin toggle" do
    built_in = Job::Kind::BUILT_IN_ENTRIES.map(&:kind)

    set_enabled(true)
    expect(Job::Kind.values).to include(*built_in)

    set_enabled(false)
    expect(Job::Kind.values).to eq(built_in)
  end
end
