require "rails_helper"
require "zlib"

RSpec.describe Syrus::ResponseCompression do
  def response_for(content_type:, body:, path: "/example", headers: {})
    app = lambda do |_env|
      response_headers = { Rack::CONTENT_TYPE => content_type, Rack::CONTENT_LENGTH => body.bytesize.to_s }.merge(headers)
      [ 200, response_headers, [ body ] ]
    end
    middleware = Rack::Deflater.new(
      app,
      include: described_class::CONTENT_TYPES,
      if: described_class.method(:compress?)
    )

    Rack::MockRequest.new(middleware).get(path, "HTTP_ACCEPT_ENCODING" => "gzip")
  end

  def inflated(response)
    Zlib::GzipReader.new(StringIO.new(response.body)).read
  end

  it "compresses large JSON, JSONL, and HTML responses" do
    described_class::CONTENT_TYPES.each do |content_type|
      body = "x" * described_class::MINIMUM_BODY_SIZE
      response = response_for(content_type: content_type, body: body)

      expect(response["Content-Encoding"]).to eq("gzip")
      expect(response["Vary"]).to eq("Accept-Encoding")
      expect(inflated(response)).to eq(body)
    end
  end

  it "does not compress tiny or server-sent event responses" do
    tiny = response_for(content_type: "application/json", body: "{}")
    events = response_for(content_type: "text/event-stream", body: "data: #{'x' * 2_000}")

    expect(tiny["Content-Encoding"]).to be_nil
    expect(events["Content-Encoding"]).to be_nil
  end

  it "does not compress Action Cable or already encoded responses" do
    cable = response_for(content_type: "application/json", body: "x" * 2_000, path: "/cable")
    encoded = response_for(
      content_type: "application/json",
      body: "x" * 2_000,
      headers: { "content-encoding" => "br" }
    )

    expect(cable["Content-Encoding"]).to be_nil
    expect(encoded["Content-Encoding"]).to eq("br")
  end

  it "is installed in the Rails middleware stack" do
    expect(Rails.application.middleware.map(&:klass)).to include(Rack::Deflater)
  end
end
