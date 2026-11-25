require "rails_helper"

RSpec.describe RuntimeImages::BuildNetwork::Session do
  let(:policy) { RuntimeImages::BuildNetwork::Policy.new([]) }

  it "serves a proxy socket for the block and removes everything afterwards" do
    dir = socket = nil
    described_class.open(policy: policy) do |session|
      dir = session.dir
      socket = session.socket_path
      expect(File.socket?(socket)).to be(true)
      expect(File.stat(socket).mode & 0o777).to eq(0o600)
      expect(session.environment.values_at("HTTP_PROXY", "https_proxy", "ALL_PROXY")).to all(eq("http://127.0.0.1:3128"))
      expect(session.environment.values_at("NO_PROXY", "no_proxy")).to all(eq(""))
      expect(session.relay_command.last(2)).to eq([ socket, "3128" ])
    end
    expect(File.exist?(socket)).to be(false)
    expect(Dir.exist?(dir)).to be(false)
  end

  it "cleans up when the block raises" do
    dir = nil
    expect { described_class.open(policy: policy) { |s| dir = s.dir; raise "boom" } }.to raise_error("boom")
    expect(Dir.exist?(dir)).to be(false)
  end
end
