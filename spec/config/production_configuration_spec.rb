require "rails_helper"

RSpec.describe "production configuration" do
  let(:production_config) { Rails.root.join("config/environments/production.rb").read }
  let(:application_mailer) { Rails.root.join("app/mailers/application_mailer.rb").read }
  let(:deploy_config) { Rails.root.join("config/deploy.yml").read }
  let(:storage_config) { Rails.root.join("config/storage.yml").read }
  let(:dockerfile) { Rails.root.join("Dockerfile").read }

  it "does not leave scaffold production host or mailer values in place" do
    expect(production_config).not_to include("example.com")
    expect(application_mailer).not_to include("example.com")
    expect(deploy_config).not_to include("example.com")
  end

  it "does not expose internal infrastructure values in config examples" do
    config_files = [ production_config, deploy_config, storage_config ]

    expect(config_files).not_to include(a_string_including("syrus.internal.green-acres.estate"))
    expect(config_files).not_to include(a_string_including("192.168.0.1"))
    expect(config_files).not_to include(a_string_including("minio.minio.svc.cluster.local"))
    expect(config_files).not_to include(a_string_including("green_acres"))
  end

  it "documents the environment-owned production host and proxy assumptions in config" do
    expect(production_config).to include('app_host = ENV.fetch("SYRUS_APP_HOST")')
    expect(production_config).to include("default_allowed_hosts = app_host")
    expect(production_config).to include('ENV.fetch("SYRUS_ALLOWED_HOSTS", default_allowed_hosts)')
    expect(production_config).to include('env_boolean.call("SYRUS_ASSUME_SSL", "true")')
    expect(production_config).to include('env_boolean.call("SYRUS_FORCE_SSL", "true")')
    expect(production_config).to include('sidecar_process = ENV["SYRUS_MCP_SIDECAR"].present? || ENV["SYRUS_CHAT_MCP_SIDECAR"].present?')
    expect(production_config).to include('log_device = sidecar_process ? STDERR : STDOUT')
    expect(production_config).to include('config.action_mailer.default_url_options = { host: app_host, protocol: "https" }')
    expect(production_config).to include("ActiveRecordEncryptionConfig.apply_env_overrides!(config)")
  end

  it "sets build-only runtime placeholders while precompiling assets" do
    expect(production_config).to include('app_host = ENV.fetch("SYRUS_APP_HOST")')
    expect(dockerfile).to include("SYRUS_APP_HOST=syrus.invalid")
    expect(dockerfile).to include("S3_ACCESS_KEY_ID=dummy")
    expect(dockerfile).to include("S3_SECRET_ACCESS_KEY=dummy")
    expect(dockerfile).to include("S3_BUCKET=syrus-build-assets")
    expect(dockerfile).to include("S3_ENDPOINT=http://127.0.0.1:9000")
    expect(dockerfile).to include("SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile")
  end
end
