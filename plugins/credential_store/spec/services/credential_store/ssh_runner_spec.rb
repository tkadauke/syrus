require "rails_helper"
require "rbconfig"

RSpec.describe CredentialStore::SshRunner do
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
