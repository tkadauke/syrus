require "rails_helper"
require "rbconfig"

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

  it "bounds TERM-resistant process groups and pipe-reader cleanup" do
    script = <<~'RUBY'
      trap("TERM") {}
      fork do
        trap("TERM") {}
        loop { sleep 1 }
      end
      loop { sleep 1 }
    RUBY
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = described_class.call(env: {}, argv: [ RbConfig.ruby, "-e", script ], timeout: 0.05)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    expect(result.status).to eq(124)
    expect(elapsed).to be < 2
  end
end
