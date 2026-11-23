require "rails_helper"

RSpec.describe GitTransportErrors do
  it "treats a GitHub HTTP/2 reset mid-clone as transient" do
    expect(described_class.transient?("error: RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly: CANCEL (err 8)")).to be(true)
    expect(described_class.transient?("fatal: early EOF")).to be(true)
    expect(described_class.transient?("error: RPC failed; curl 56 Recv failure: Connection reset by peer")).to be(true)
  end

  it "does not treat a statement about the repository as transient, even beside a dropped connection" do
    expect(described_class.transient?("fatal: repository not found\nfatal: early EOF")).to be(false)
    expect(described_class.transient?("! [rejected] main -> main (non-fast-forward)")).to be(false)
  end
end
