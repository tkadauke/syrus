require "rails_helper"
require "open3"
require "socket"

RSpec.describe "bin/runtime-image-build-relay" do
  it "pipes loopback TCP connections to the proxy's Unix socket" do
    dir = Dir.mktmpdir("rib-relay")
    path = File.join(dir, "p.sock")
    server = UNIXServer.new(path)
    echo = Thread.new { loop { c = server.accept; c.write("hello:#{c.readpartial(10)}"); c.close } }
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
    pid = Process.spawn(RbConfig.ruby, Rails.root.join("bin/runtime-image-build-relay").to_s, path, port.to_s, %i[out err] => File::NULL)
    sock = nil
    50.times { begin; sock = TCPSocket.new("127.0.0.1", port); break; rescue SystemCallError; sleep 0.1; end }
    sock.write("ping")
    expect(sock.readpartial(20)).to eq("hello:ping")
  ensure
    sock&.close
    Process.kill("TERM", pid) if pid
    Process.wait(pid) if pid
    echo&.kill
    server&.close
    FileUtils.rm_rf(dir)
  end

  it "refuses to start without arguments" do
    _out, err, status = Open3.capture3(RbConfig.ruby, Rails.root.join("bin/runtime-image-build-relay").to_s)
    expect(status).not_to be_success
    expect(err).to include("usage")
  end
end
