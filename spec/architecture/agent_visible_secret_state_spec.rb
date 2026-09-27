require "rails_helper"

RSpec.describe "agent-visible sidecar configuration" do
  SECRET_ENV = {
    "RAILS_MASTER_KEY" => "poison-rails-master-key",
    "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "poison-ar-primary",
    "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "poison-ar-deterministic",
    "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "poison-ar-salt",
    "SECRET_KEY_BASE" => "poison-secret-key-base",
    "DATABASE_URL" => "mysql2://syrus:poison-db@syrus-mysql/syrus_production",
    "SYRUS_DATABASE_PASSWORD" => "poison-db-password",
    "S3_ACCESS_KEY_ID" => "poison-s3-access-key",
    "S3_SECRET_ACCESS_KEY" => "poison-s3-secret-key",
    "RETENTION_ARCHIVE_S3_ACCESS_KEY_ID" => "poison-retention-access-key",
    "RETENTION_ARCHIVE_S3_SECRET_ACCESS_KEY" => "poison-retention-secret-key"
  }.freeze

  SAFE_ENV = {
    "RAILS_ENV" => "production",
    "RAILS_LOG_LEVEL" => "info",
    "SYRUS_SQLITE" => "1",
    "SYRUS_DATA_ROOT" => "/home/rails/.syrus",
    "BUNDLE_PATH" => "/usr/local/bundle",
    "PATH" => "/usr/local/bin:/usr/bin:/bin",
    "S3_BUCKET" => "syrus-attachments",
    "S3_ENDPOINT" => "http://minio:9000",
    "S3_REGION" => "us-east-1"
  }.freeze

  SECRET_PATHS = %w[
    .env
    config/master.key
    config/credentials
    config/database.yml
    /run/syrus/sidecar.env
    /run/secrets/syrus_sidecar_env
  ].freeze

  it "does not place instance secret keys, values, or secret file paths in MCP env templates" do
    env = AgentSidecarEnvironment.build(env: SAFE_ENV.merge(SECRET_ENV))
    serialized = JSON.generate({
      mcpServers: {
        "syrus-mcp-sidecar" => {
          type: "stdio",
          command: Rails.root.join("bin/syrus-mcp-sidecar").to_s,
          args: [ "--run-id", "123" ],
          env: env,
          alwaysLoad: true
        }
      }
    })

    expect(env).to include(
      "RAILS_ENV" => "production",
      "SYRUS_SQLITE" => "1",
      "S3_BUCKET" => "syrus-attachments",
      "GEM_HOME" => "/usr/local/bundle",
      "GEM_PATH" => "/usr/local/bundle"
    )

    expect(env.keys).not_to include(*SECRET_ENV.keys)
    expect(env.values).not_to include(*SECRET_ENV.values)
    expect(serialized).not_to include(*SECRET_ENV.keys)
    expect(serialized).not_to include(*SECRET_ENV.values)
    expect(serialized).not_to include(*SECRET_PATHS)
  end

  it "keeps the public allowlist disjoint from instance secret keys" do
    expect(AgentSidecarEnvironment::SAFE_ENV_FORWARD & AgentSidecarEnvironment::SECRET_ENV_KEYS).to be_empty
    expect(AgentProviders::Base::SIDECAR_ENV_FORWARD & AgentSidecarEnvironment::SECRET_ENV_KEYS).to be_empty
  end
end
