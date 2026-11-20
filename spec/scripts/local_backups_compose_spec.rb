require "rails_helper"
require "yaml"

RSpec.describe "Local Backups Compose storage" do
  let(:compose) { Rails.root.join("docker-compose.yml").read }

  it "uses a dedicated host-visible mount with web read-only and worker read-write" do
    expect(compose.scan(/SYRUS_BACKUP_HOST_PATH/).length).to eq(3)
    expect(compose).to include('${SYRUS_BACKUP_HOST_PATH:-./local-backups}:/home/rails/.syrus-backups:ro')
    expect(compose).to include('${SYRUS_BACKUP_HOST_PATH:-./local-backups}:/home/rails/.syrus-backups')
  end


  it "maps one host path into every backup consumer with role-appropriate permissions" do
    parsed = YAML.safe_load(compose, aliases: true)
    mounts = %w[setup web worker].to_h do |service|
      volume = parsed.fetch("services").fetch(service).fetch("volumes")
        .find { |entry| entry.include?("SYRUS_BACKUP_HOST_PATH") }
      match = /\A(.+):(\/[^:]+)(?::(ro))?\z/.match(volume)
      [ service, match.captures ]
    end

    expect(mounts.values.map(&:first).uniq).to eq([ "${SYRUS_BACKUP_HOST_PATH:-./local-backups}" ])
    expect(mounts.values.map { |parts| parts.fetch(1) }.uniq).to eq([ "/home/rails/.syrus-backups" ])
    expect(mounts.fetch("web").fetch(2)).to eq("ro")
    expect(mounts.fetch("setup").fetch(2)).to be_nil
    expect(mounts.fetch("worker").fetch(2)).to be_nil
  end
end
