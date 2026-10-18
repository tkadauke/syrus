require "rails_helper"

RSpec.describe CredentialStore::SshRunner do
  it "preserves separate output streams and records the brokered command" do
    result = described_class.call(
      env: {},
      argv: [ RbConfig.ruby, "-e", '$stdout.write("remote out"); $stderr.write("remote err")' ]
    )

    expect(result).to be_success
    expect(result.stdout).to eq("remote out")
    expect(result.stderr).to eq("remote err")
    expect(SpawnedProcess.order(:id).last).to have_attributes(
      kind: "chat_shell_command", outcome: "succeeded", exit_status: 0
    )
  end
end
