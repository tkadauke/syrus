require "rails_helper"

RSpec.describe "Local Backups Compose storage" do
  let(:compose) { Rails.root.join("docker-compose.yml").read }

  it "uses a dedicated host-visible mount with web read-only and worker read-write" do
    expect(compose.scan(/SYRUS_BACKUP_HOST_PATH/).length).to eq(3)
    expect(compose).to include('${SYRUS_BACKUP_HOST_PATH:-./local-backups}:/home/rails/.syrus-backups:ro')
    expect(compose).to match(/SYRUS_BACKUP_HOST_PATH:-\.\/local-backups}:\/home\/rails\/\.syrus-backups\n/)
  end
end
