require "rails_helper"

RSpec.describe Syrus::PluginSettings do
  def register(schema)
    Syrus::PluginRegistry.register(name: "configurable", version: "1.0.0", config_schema: schema)
  end

  it "returns the schema default when nothing has been saved" do
    register([ { key: "hostname", type: :string, default: "syrus" } ])

    expect(described_class.get("configurable", :hostname)).to eq("syrus")
  end

  it "returns the operator's saved value over the default" do
    register([ { key: "hostname", type: :string, default: "syrus" } ])
    PluginRecord.find_or_create_by!(name: "configurable").update!(config: { "settings" => { "hostname" => "custom" } })

    expect(described_class.get("configurable", :hostname)).to eq("custom")
  end

  it "reads a secret_env value from the environment, never the database" do
    register([ { key: "auth_key", type: :secret_env, env_var: "TEST_PLUGIN_AUTH_KEY" } ])
    PluginRecord.find_or_create_by!(name: "configurable").update!(config: { "settings" => { "auth_key" => "leaked" } })

    expect(described_class.get("configurable", :auth_key)).to be_nil

    ENV["TEST_PLUGIN_AUTH_KEY"] = "from-env"
    expect(described_class.get("configurable", :auth_key)).to eq("from-env")
  ensure
    ENV.delete("TEST_PLUGIN_AUTH_KEY")
  end

  it "returns nil for a key the schema does not declare" do
    register([ { key: "hostname", type: :string, default: "syrus" } ])

    expect(described_class.get("configurable", :nonexistent)).to be_nil
  end

  it "returns nil for an unregistered plugin" do
    expect(described_class.get("no_such_plugin", :anything)).to be_nil
  end

  it "reports presence for booleans and blank strings" do
    register([
      { key: "flag", type: :boolean, default: false },
      { key: "blank", type: :string, default: "" }
    ])
    settings = described_class.for("configurable")

    expect(settings.present?(:flag)).to be(true)
    expect(settings.present?(:blank)).to be(false)
  end

  it "exposes the whole resolved schema as a hash" do
    register([
      { key: "hostname", type: :string, default: "syrus" },
      { key: "exit_node", type: :boolean, default: false }
    ])

    expect(described_class.for("configurable").to_h).to eq({ "hostname" => "syrus", "exit_node" => false })
  end
end
