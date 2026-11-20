require "rails_helper"

RSpec.describe LocalBackups::Alerts do
  before do
    PluginRecord.find_by!(name: "local_backups").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "alerts administrators about recent creation failures without exposing error details" do
    LocalBackups::Backup.create!(
      uuid: SecureRandom.uuid, state: "failed", artifact_relative_path: ".failed.partial", manifest_version: "1",
      failed_at: Time.current, error_class: "SecretError", error_summary: "token=do-not-render"
    )

    alert = described_class.system_alerts.find { |candidate| candidate.id == "local_backups:failed" }

    expect(alert).to have_attributes(severity: :alarm, title: "Local backup creation failed.")
    expect(alert.message).not_to include("SecretError", "do-not-render")
  end

  it "alerts administrators when retained backups are invalid" do
    LocalBackups::Backup.create!(
      uuid: SecureRandom.uuid, state: "completed", artifact_relative_path: "sealed", manifest_version: "1",
      completed_at: Time.current, verification_state: "invalid"
    )

    expect(described_class.system_alerts).to include(have_attributes(id: "local_backups:invalid", severity: :warn))
  end

  it "contributes alerts through the enabled plugin registry" do
    admin = Factories.user(admin: true)
    LocalBackups::Backup.create!(
      uuid: SecureRandom.uuid, state: "failed", artifact_relative_path: ".failed.partial", manifest_version: "1",
      failed_at: Time.current
    )

    expect(SystemAlerts.active_for(user: admin)).to include(have_attributes(id: "local_backups:failed"))
  end
end
