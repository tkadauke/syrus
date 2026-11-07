require "rails_helper"

RSpec.describe Syrus::PrecompressedAssetServer do
  around do |example|
    Dir.mktmpdir do |directory|
      @root = Pathname.new(directory)
      (@root / "assets").mkpath
      example.run
    end
  end

  def request(app, path = "/assets/app.js")
    status, headers, body = app.call(Rack::MockRequest.env_for(path))
    [ status, headers, body.each.to_a.join ]
  end

  it "reuses cached bytes, size, and digest while the asset is unchanged" do
    path = @root / "assets/app.js"
    path.binwrite("first asset")
    app = described_class.new(->(_env) { [ 404, {}, [] ] }, root: @root, prefix: "/assets")
    allow(Digest::SHA256).to receive(:hexdigest).and_call_original
    allow(File).to receive(:binread).and_call_original

    first = request(app)
    second = request(app)

    expect(second).to eq(first)
    expect(Digest::SHA256).to have_received(:hexdigest).once
    expect(File).to have_received(:binread).once
  end

  it "refreshes cached metadata and bytes when the asset mtime changes" do
    path = @root / "assets/app.js"
    path.binwrite("first asset")
    original_mtime = path.mtime
    app = described_class.new(->(_env) { [ 404, {}, [] ] }, root: @root, prefix: "/assets")
    _status, first_headers, first_body = request(app)

    path.binwrite("second asset with a different size")
    File.utime(original_mtime + 1, original_mtime + 1, path)
    _status, second_headers, second_body = request(app)

    expect(second_body).to eq("second asset with a different size")
    expect(second_body).not_to eq(first_body)
    expect(second_headers[Rack::CONTENT_LENGTH]).to eq(second_body.bytesize.to_s)
    expect(second_headers[Rack::ETAG]).not_to eq(first_headers[Rack::ETAG])
  end
end
