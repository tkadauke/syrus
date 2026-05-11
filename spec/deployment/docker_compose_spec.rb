require "rails_helper"
require "yaml"

RSpec.describe "Docker Compose self-host deployment" do
  let(:root) { Rails.root }
  let(:compose) { YAML.safe_load_file(root.join("docker-compose.yml"), aliases: true) }
  let(:services) { compose.fetch("services") }
  let(:env_example) { root.join(".env.example").read }
  let(:dockerfile) { root.join("docker/Dockerfile").read }
  let(:readme) { root.join("docker/README.md").read }

  it "defines web, worker, and MySQL services with persistent volumes" do
    expect(services.keys).to include("web", "worker", "db")

    expect(services.dig("web", "ports")).to include("${SYRUS_WEB_PORT:-3000}:80")
    expect(services.dig("worker", "command")).to eq([ "./bin/jobs" ])

    expect(services.dig("web", "volumes")).to include(
      "syrus_data:${SYRUS_DATA_ROOT:-/home/rails/.syrus}",
      "syrus_storage:/rails/storage"
    )
    expect(services.dig("worker", "volumes")).to include(
      "syrus_data:${SYRUS_DATA_ROOT:-/home/rails/.syrus}",
      "syrus_storage:/rails/storage"
    )
    expect(services.dig("db", "volumes")).to include("mysql_data:/var/lib/mysql")
    expect(compose.fetch("volumes").keys).to include("mysql_data", "syrus_data", "syrus_storage")
  end

  it "uses the full production image target for both Rails processes" do
    expect(services.dig("web", "image")).to eq("${SYRUS_IMAGE:-ghcr.io/tkadauke/syrus:full}")
    expect(services.dig("worker", "image")).to eq("${SYRUS_IMAGE:-ghcr.io/tkadauke/syrus:full}")
    expect(services.dig("web", "build", "dockerfile")).to eq("docker/Dockerfile")
    expect(services.dig("web", "build", "target")).to eq("full")
    expect(services.dig("worker", "build", "target")).to eq("full")
    expect(dockerfile).to include("FROM worker-dev AS full")
  end

  it "documents required operator configuration" do
    %w[
      RAILS_MASTER_KEY
      SECRET_KEY_BASE
      SYRUS_DATABASE_PASSWORD
      MYSQL_ROOT_PASSWORD
      SYRUS_DATA_ROOT
      JOB_CONCURRENCY
    ].each do |name|
      expect(env_example).to include(name)
      expect(readme).to include(name)
    end

    expect(readme).to include("docker compose up")
    expect(readme).to include("docker compose pull")
    expect(readme).to include("mysqldump")
    expect(readme).to include("ghcr.io/tkadauke/syrus:eval-latest")
  end

  it "has healthchecks for all compose services" do
    expect(services.dig("db", "healthcheck", "test").join(" ")).to include("mysqladmin ping")
    expect(services.dig("web", "healthcheck", "test").join(" ")).to include("/up")
    expect(services.dig("worker", "healthcheck", "test").join(" ")).to include("SolidQueue::Process")
  end
end
