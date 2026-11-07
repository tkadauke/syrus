require "rails_helper"

RSpec.describe Syrus::PrecompressedAssetServer do
  around do |example|
    Dir.mktmpdir("precompressed-assets") do |directory|
      @root = Pathname.new(directory)
      example.run
    end
  end

  def middleware
    described_class.new(->(_env) { [ 404, {}, [] ] }, root: @root, prefix: "/assets")
  end

  it "reuses asset size and digest until the file mtime changes" do
    asset = @root.join("assets/example.js")
    asset.dirname.mkpath
    asset.binwrite("first body")
    server = middleware
    request = Rack::MockRequest.new(server)
    allow(Digest::SHA256).to receive(:file).and_call_original

    first = request.get("/assets/example.js")
    second = request.get("/assets/example.js")

    expect(second["ETag"]).to eq(first["ETag"])
    expect(Digest::SHA256).to have_received(:file).once

    asset.binwrite("replacement body")
    changed_at = Time.now + 2
    File.utime(changed_at, changed_at, asset)
    changed = request.get("/assets/example.js")

    expect(changed["ETag"]).not_to eq(first["ETag"])
    expect(changed["Content-Length"]).to eq("replacement body".bytesize.to_s)
    expect(Digest::SHA256).to have_received(:file).twice
  end
end
