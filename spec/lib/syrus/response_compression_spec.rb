require "rails_helper"
require "stringio"
require "zlib"

RSpec.describe Syrus::ResponseCompression do
  def response(content_type:, body:, path: "/api/v1/app/example", headers: {})
    app = lambda do |_env|
      response_headers = {
        Rack::CONTENT_TYPE => content_type,
        Rack::CONTENT_LENGTH => body.bytesize.to_s
      }.merge(headers)
      [ 200, response_headers, [ body ] ]
    end
    middleware = Rack::Deflater.new(
      app,
      include: described_class::CONTENT_TYPES,
      if: described_class.method(:eligible?)
    )
    env = Rack::MockRequest.env_for(path, "HTTP_ACCEPT_ENCODING" => "gzip")
    status, response_headers, response_body = middleware.call(env)
    chunks = []
    response_body.each { |chunk| chunks << chunk }
    response_body.close if response_body.respond_to?(:close)
    [ status, response_headers, chunks.join ]
  end

  def gunzip(body)
    Zlib::GzipReader.new(StringIO.new(body)).read
  end

  it "compresses large JSON, JSONL, and HTML responses" do
    described_class::CONTENT_TYPES.each do |content_type|
      original = "compressible response " * 100
      _status, headers, body = response(content_type: "#{content_type}; charset=utf-8", body: original)

      expect(headers["content-encoding"]).to eq("gzip")
      expect(gunzip(body)).to eq(original)
    end
  end

  it "does not compress tiny responses" do
    _status, headers, body = response(content_type: "application/json", body: %({"ok":true}))

    expect(headers["content-encoding"]).to be_nil
    expect(body).to eq(%({"ok":true}))
  end

  it "does not compress event streams or Action Cable responses" do
    original = "stream payload " * 100
    _status, stream_headers, = response(content_type: "text/event-stream", body: original)
    _status, cable_headers, = response(content_type: "application/json", body: original, path: "/cable")

    expect(stream_headers["content-encoding"]).to be_nil
    expect(cable_headers["content-encoding"]).to be_nil
  end

  it "preserves responses already encoded by another layer" do
    original = "already encoded " * 100
    _status, headers, body = response(
      content_type: "application/json",
      body: original,
      headers: { "Content-Encoding" => "br" }
    )

    expect(headers["Content-Encoding"]).to eq("br")
    expect(body).to eq(original)
  end

  it "does not consume unknown-length bodies while deciding eligibility" do
    body = Class.new do
      attr_reader :iterations

      def initialize
        @iterations = 0
      end

      def each
        @iterations += 1
        yield("large response " * 100)
      end
    end.new

    expect(described_class.eligible?({ "PATH_INFO" => "/api" }, 200, {}, body)).to be true
    expect(body.iterations).to eq(0)
  end

  it "uses a non-streaming Rack body's array representation to skip tiny responses" do
    body = instance_double("RackBody", to_ary: [ %({"ok":true}) ])

    expect(described_class.eligible?({ "PATH_INFO" => "/api" }, 200, {}, body)).to be false
  end
end
