require "rails_helper"

RSpec.describe MysqlDbBrowser::ListConnectionsTool do
  it "returns only safe connection metadata, including agentic and write flags" do
    enabled = Factories.mysql_connection(
      label: "Production reporting",
      host: "prod-db.internal",
      port: 3307,
      username: "reporter",
      password: "s3cret",
      default_database: "reporting",
      agentic_access_enabled: true,
      allow_writes: false
    )
    disabled = Factories.mysql_connection(
      label: "Archive",
      host: "archive-db.internal",
      username: "archive_user",
      password: "archive-secret",
      default_database: "archive",
      agentic_access_enabled: false,
      allow_writes: true
    )

    response = described_class.call(server_context: {})

    expect(response.error?).to be(false)
    payload = JSON.parse(response.content.first[:text])
    expect(payload.fetch("mysql_connections")).to contain_exactly(
      {
        "id" => enabled.id,
        "label" => "Production reporting",
        "default_database" => "reporting",
        "agentic_access_enabled" => true,
        "allow_writes" => false,
        "created_at" => enabled.created_at.iso8601,
        "updated_at" => enabled.updated_at.iso8601
      },
      {
        "id" => disabled.id,
        "label" => "Archive",
        "default_database" => "archive",
        "agentic_access_enabled" => false,
        "allow_writes" => true,
        "created_at" => disabled.created_at.iso8601,
        "updated_at" => disabled.updated_at.iso8601
      }
    )

    serialized = response.content.first[:text]
    expect(serialized).not_to include("prod-db.internal")
    expect(serialized).not_to include("reporter")
    expect(serialized).not_to include("s3cret")
    expect(serialized).not_to include("archive-db.internal")
    expect(serialized).not_to include("archive_user")
    expect(serialized).not_to include("archive-secret")
  end
end
