require "rails_helper"

RSpec.describe AdminMysql::PermissionProvider do
  it "separates observation from exact-invocation query interruption" do
    observe = described_class.capability_descriptor("mysql.admin/status@v1")
    kill = described_class.capability_descriptor("mysql.admin/kill_query@v1")

    expect(observe).to have_attributes(capability: "mysql.admin.observe@v1", risk: :medium, maximum_autonomy: :job)
    expect(observe.defaults.values.uniq).to eq([ :allow ])
    expect(kill).to have_attributes(
      capability: "mysql.admin.kill_query@v1", risk: :critical,
      maximum_autonomy: :invocation, authority_durations: [ :invocation ]
    )
    expect(kill.defaults).to eq(AgentRole::CHAT_PLANNER => :ask)
  end

  it "scopes both capabilities to this Syrus instance without retaining statement text" do
    schema = described_class.permission_resource_scopes.fetch(:syrus_database)
    descriptor = described_class.capability_descriptor("mysql.admin/kill_query@v1")

    expect(schema.normalize({ "database" => "another" }, context: {}).value).to eq("database" => "syrus")
    expect(descriptor.normalize_fingerprint(thread_id: 42, statement: "SELECT secret")).to eq("thread_id" => 42)
    expect(descriptor.redact(thread_id: 42, statement: "SELECT secret").to_json).not_to include("secret")
  end
end
