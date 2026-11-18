require "rails_helper"
require "yaml"

RSpec.describe "external plugin Compose volume" do
  let(:compose) { YAML.safe_load(Rails.root.join("docker-compose.yml").read, aliases: true) }

  it "mounts the plugin volume read-only in every Rails service" do
    %w[setup web worker preview].each do |service_name|
      service = compose.fetch("services").fetch(service_name)

      expect(service.fetch("environment")).to include("SYRUS_PLUGIN_PATH" => "/home/rails/.syrus-plugins")
      expect(service.fetch("volumes")).to include("syrus-plugins:/home/rails/.syrus-plugins:ro")
    end
  end

  it "reserves write access for the inert installer service" do
    installer = compose.fetch("services").fetch("plugin-installer")

    expect(installer.fetch("profiles")).to eq([ "plugin-installer" ])
    expect(installer.fetch("command")).to eq([ "/bin/true" ])
    expect(installer.fetch("volumes")).to eq([ "syrus-plugins:/home/rails/.syrus-plugins" ])
  end

  it "keeps setup on the image entrypoint so sync precedes migrations" do
    setup = compose.fetch("services").fetch("setup")

    expect(setup).not_to have_key("entrypoint")
    expect(setup.fetch("command").first(2)).to eq([ "/bin/bash", "-euc" ])
    %w[web worker preview].each do |service_name|
      expect(compose.fetch("services").fetch(service_name)).not_to have_key("entrypoint")
    end
  end
end
