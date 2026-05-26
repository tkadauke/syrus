require "rails_helper"

RSpec.describe "production configuration" do
  let(:production_config) { Rails.root.join("config/environments/production.rb").read }
  let(:application_mailer) { Rails.root.join("app/mailers/application_mailer.rb").read }
  let(:deploy_config) { Rails.root.join("config/deploy.yml").read }

  it "does not leave scaffold production host or mailer values in place" do
    expect(production_config).not_to include("example.com")
    expect(application_mailer).not_to include("example.com")
    expect(deploy_config).not_to include("example.com")
  end

  it "documents the environment-owned production host and proxy assumptions in config" do
    expect(production_config).to include('ENV.fetch("SYRUS_APP_HOST", "agents.green-acres.estate")')
    expect(production_config).to include('ENV.fetch("SYRUS_ALLOWED_HOSTS", app_host)')
    expect(production_config).to include('env_boolean.call("SYRUS_ASSUME_SSL", "true")')
    expect(production_config).to include('env_boolean.call("SYRUS_FORCE_SSL", "true")')
    expect(production_config).to include('config.action_mailer.default_url_options = { host: app_host, protocol: "https" }')
  end
end
