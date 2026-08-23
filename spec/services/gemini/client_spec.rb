require "rails_helper"

RSpec.describe Gemini::Client do
  let(:client) { described_class.new(api_key: "AIza-test-key") }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  describe "#list_models" do
    it "strips the models/ prefix and authenticates with the x-goog-api-key header" do
      stub_request(:get, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=50")
        .with(headers: { "x-goog-api-key" => "AIza-test-key" })
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            models: [
              { name: "models/gemini-3.5-flash" },
              { name: "models/gemini-embedding-001" }
            ]
          }.to_json
        )

      expect(client.list_models).to eq(%w[ gemini-3.5-flash gemini-embedding-001 ])
    end
  end

  describe "#resolve_video_model!" do
    def stub_models(names)
      stub_request(:get, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=50")
        .to_return(
          status: 200,
          headers: json_headers,
          body: { models: names.map { |n| { name: "models/#{n}" } } }.to_json
        )
    end

    it "picks gemini-3.5-flash when the project exposes it" do
      stub_models(%w[gemini-3.5-flash gemini-2.5-flash gemini-embedding-001])

      expect(client.resolve_video_model!).to eq("gemini-3.5-flash")
      expect(client.model).to eq("gemini-3.5-flash")
    end

    it "falls back to gemini-2.5-flash when 3.5 is absent and uses it for the next generateContent" do
      stub_models(%w[gemini-2.5-flash gemini-embedding-001])

      expect(client.resolve_video_model!).to eq("gemini-2.5-flash")
      expect(client.model).to eq("gemini-2.5-flash")

      # The resolved fallback model must drive the subsequent request URL —
      # otherwise a key validated against a fallback 404s on the default.
      fallback_endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
      stub_request(:post, fallback_endpoint).to_return(
        status: 200,
        headers: json_headers,
        body: { candidates: [ { content: { parts: [ { text: { "ok" => true }.to_json } ] } } ] }.to_json
      )

      client.generate_content(
        file_uri: "https://generativelanguage.googleapis.com/v1beta/files/abc",
        mime_type: "video/webm",
        prompt: "Analyze.",
        response_schema: { type: "OBJECT" }
      )

      expect(WebMock).to have_requested(:post, fallback_endpoint)
    end

    it "raises Error when no video-capable model is available to the project" do
      stub_models(%w[gemini-embedding-001 text-bison])

      expect { client.resolve_video_model! }.to raise_error(Gemini::Client::Error, /no video-capable Gemini model/)
    end
  end

  describe "transport failures" do
    it "wraps a list_models transport failure as ConnectionError, not a raw error" do
      stub_request(:get, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=50")
        .to_raise(Errno::ECONNRESET)

      expect { client.list_models }.to raise_error(Gemini::Client::ConnectionError, /could not reach Gemini/)
    end

    it "wraps a generate_content transport failure as ConnectionError, not a raw error" do
      stub_request(:post, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
        .to_raise(SocketError)

      expect {
        client.generate_content(
          file_uri: "https://generativelanguage.googleapis.com/v1beta/files/abc",
          mime_type: "video/webm",
          prompt: "Analyze.",
          response_schema: { type: "OBJECT" }
        )
      }.to raise_error(Gemini::Client::ConnectionError, /could not reach Gemini/)
    end
  end

  describe "#upload_file" do
    it "runs the two-step resumable upload and returns the file record" do
      stub_request(:post, "https://generativelanguage.googleapis.com/upload/v1beta/files")
        .to_return(
          status: 200,
          headers: { "x-goog-upload-url" => "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=abc123" }
        )
      stub_request(:post, "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=abc123")
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            file: { name: "files/abc", uri: "https://generativelanguage.googleapis.com/v1beta/files/abc", state: "PROCESSING" }
          }.to_json
        )

      file = client.upload_file(
        io: StringIO.new("vidbytes"),
        byte_size: 8,
        content_type: "video/webm",
        display_name: "Walkthrough video"
      )

      expect(file).to include(
        "name" => "files/abc",
        "uri" => "https://generativelanguage.googleapis.com/v1beta/files/abc",
        "state" => "PROCESSING"
      )

      expect(WebMock).to have_requested(:post, "https://generativelanguage.googleapis.com/upload/v1beta/files")
        .with(
          headers: {
            "X-Goog-Upload-Protocol" => "resumable",
            "X-Goog-Upload-Command" => "start",
            "X-Goog-Upload-Header-Content-Length" => "8",
            "X-Goog-Upload-Header-Content-Type" => "video/webm",
            "x-goog-api-key" => "AIza-test-key"
          },
          body: { file: { display_name: "Walkthrough video" } }.to_json
        )
      expect(WebMock).to have_requested(:post, "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=abc123")
        .with(
          headers: {
            "X-Goog-Upload-Command" => "upload, finalize",
            "X-Goog-Upload-Offset" => "0",
            "Content-Length" => "8"
          },
          body: "vidbytes"
        )
    end

    it "raises when Gemini does not return a resumable upload URL" do
      stub_request(:post, "https://generativelanguage.googleapis.com/upload/v1beta/files")
        .to_return(status: 200, headers: {})

      expect {
        client.upload_file(io: StringIO.new("x"), byte_size: 1, content_type: "video/webm", display_name: "w")
      }.to raise_error(Gemini::Client::Error, /did not return a resumable upload URL/)
    end
  end

  describe "#wait_until_active" do
    let(:file_url) { "https://generativelanguage.googleapis.com/v1beta/files/abc" }

    it "polls until the file turns ACTIVE and returns it" do
      stub_request(:get, file_url)
        .to_return(
          { status: 200, headers: json_headers, body: { name: "files/abc", state: "PROCESSING" }.to_json },
          { status: 200, headers: json_headers, body: { name: "files/abc", state: "ACTIVE" }.to_json }
        )

      file = client.wait_until_active("files/abc", sleeper: ->(_s) {})

      expect(file).to include("name" => "files/abc", "state" => "ACTIVE")
      expect(WebMock).to have_requested(:get, file_url).twice
    end

    it "raises FileProcessingFailed when the file lands in state FAILED" do
      stub_request(:get, file_url)
        .to_return(status: 200, headers: json_headers, body: { name: "files/abc", state: "FAILED" }.to_json)

      expect {
        client.wait_until_active("files/abc", sleeper: ->(_s) {})
      }.to raise_error(Gemini::Client::FileProcessingFailed, /could not process the video/)
    end

    it "raises when the file never turns ACTIVE before the deadline" do
      stub_request(:get, file_url)
        .to_return(status: 200, headers: json_headers, body: { name: "files/abc", state: "PROCESSING" }.to_json)

      expect {
        client.wait_until_active("files/abc", timeout: 0, sleeper: ->(_s) {})
      }.to raise_error(Gemini::Client::Error, /timed out waiting/)
    end
  end

  describe "#generate_content" do
    let(:endpoint) { "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent" }
    let(:response_schema) { { type: "OBJECT", properties: { summary: { type: "STRING" } } } }

    def stub_generate(text:)
      stub_request(:post, endpoint).to_return(
        status: 200,
        headers: json_headers,
        body: { candidates: [ { content: { parts: [ { text: text } ] } } ] }.to_json
      )
    end

    def generate(media_resolution: :default)
      client.generate_content(
        file_uri: "https://generativelanguage.googleapis.com/v1beta/files/abc",
        mime_type: "video/webm",
        prompt: "Analyze the walkthrough.",
        response_schema: response_schema,
        media_resolution: media_resolution
      )
    end

    it "posts a JSON responseSchema and parses the structured reply text" do
      analysis = { "summary" => "Checkout works, totals do not." }
      stub_generate(text: analysis.to_json)

      expect(generate).to eq(analysis)

      expect(WebMock).to(have_requested(:post, endpoint).with do |req|
        body = JSON.parse(req.body)
        config = body.fetch("generationConfig")
        parts = body.dig("contents", 0, "parts")

        config["responseMimeType"] == "application/json" &&
          config["responseSchema"] == { "type" => "OBJECT", "properties" => { "summary" => { "type" => "STRING" } } } &&
          !config.key?("mediaResolution") &&
          parts[0] == { "file_data" => { "file_uri" => "https://generativelanguage.googleapis.com/v1beta/files/abc", "mime_type" => "video/webm" } } &&
          parts[1] == { "text" => "Analyze the walkthrough." }
      end)
    end

    # Resolution-quality fix: the caller drives media resolution explicitly
    # (:low is the graceful-degradation fallback, not a duration-derived
    # decision inside the client). :low adds MEDIA_RESOLUTION_LOW; :default
    # (or omitted) leaves it off so full-res reads small on-screen text.
    it "adds MEDIA_RESOLUTION_LOW when media_resolution is :low" do
      stub_generate(text: { "summary" => "long one" }.to_json)

      generate(media_resolution: :low)

      expect(WebMock).to(have_requested(:post, endpoint).with do |req|
        JSON.parse(req.body).dig("generationConfig", "mediaResolution") == "MEDIA_RESOLUTION_LOW"
      end)
    end

    it "omits mediaResolution when media_resolution is :default" do
      stub_generate(text: { "summary" => "short one" }.to_json)

      generate(media_resolution: :default)

      expect(WebMock).to(have_requested(:post, endpoint).with do |req|
        !JSON.parse(req.body).fetch("generationConfig").key?("mediaResolution")
      end)
    end

    it "omits mediaResolution when media_resolution is omitted (defaults to full)" do
      stub_generate(text: { "summary" => "default one" }.to_json)

      client.generate_content(
        file_uri: "https://generativelanguage.googleapis.com/v1beta/files/abc",
        mime_type: "video/webm",
        prompt: "Analyze the walkthrough.",
        response_schema: response_schema
      )

      expect(WebMock).to(have_requested(:post, endpoint).with do |req|
        !JSON.parse(req.body).fetch("generationConfig").key?("mediaResolution")
      end)
    end

    it "raises AuthError when the key is rejected" do
      [ 401, 403 ].each do |status|
        stub_request(:post, endpoint).to_return(
          status: status,
          headers: json_headers,
          body: { error: { message: "API key not valid." } }.to_json
        )

        expect { generate }.to raise_error(Gemini::Client::AuthError, "API key not valid.")
      end
    end

    it "raises RateLimited on 429" do
      stub_request(:post, endpoint).to_return(
        status: 429,
        headers: json_headers,
        body: { error: { message: "Resource has been exhausted." } }.to_json
      )

      expect { generate }.to raise_error(Gemini::Client::RateLimited, "Resource has been exhausted.")
    end

    it "raises when the reply text is not valid JSON despite the schema" do
      stub_generate(text: "not json {")

      expect { generate }.to raise_error(Gemini::Client::Error, /malformed JSON/)
    end

    # Regression: long responses arrive split across multiple text parts (the
    # official SDKs join them). Reading only parts[0] truncated the JSON
    # mid-object and misreported a successful analysis as malformed.
    it "joins multiple text parts before parsing the JSON" do
      stub_request(:post, endpoint).to_return(
        status: 200,
        headers: json_headers,
        body: {
          candidates: [ { content: { parts: [ { text: '{"a":' }, { text: "1}" } ] } } ]
        }.to_json
      )

      expect(generate).to eq({ "a" => 1 })
    end

    # Regression: an empty analysis surfaces the finishReason so a SAFETY /
    # MAX_TOKENS cutoff is diagnosable instead of a bare "empty analysis".
    it "includes the finish reason when the parts carry no text" do
      stub_request(:post, endpoint).to_return(
        status: 200,
        headers: json_headers,
        body: {
          candidates: [ { finishReason: "SAFETY", content: { parts: [ {} ] } } ]
        }.to_json
      )

      expect { generate }.to raise_error(Gemini::Client::Error, /empty analysis.*SAFETY/)
    end
  end

  describe "#generate_text" do
    let(:endpoint) { "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent" }
    let(:response_schema) { { type: "OBJECT", properties: { frequency: { type: "STRING" } } } }

    it "posts a text-only part with a JSON responseSchema and parses the reply" do
      stub_request(:post, endpoint).to_return(
        status: 200,
        headers: json_headers,
        body: { candidates: [ { content: { parts: [ { text: { "frequency" => "DAILY" }.to_json } ] } } ] }.to_json
      )

      result = client.generate_text(prompt: "Interpret this cadence.", response_schema: response_schema)

      expect(result).to eq({ "frequency" => "DAILY" })
      expect(WebMock).to(have_requested(:post, endpoint).with do |req|
        body = JSON.parse(req.body)
        parts = body.dig("contents", 0, "parts")

        parts == [ { "text" => "Interpret this cadence." } ]
      end)
    end

    it "raises when the reply text is not valid JSON" do
      stub_request(:post, endpoint).to_return(
        status: 200,
        headers: json_headers,
        body: { candidates: [ { content: { parts: [ { text: "not json {" } ] } } ] }.to_json
      )

      expect { client.generate_text(prompt: "x", response_schema: response_schema) }
        .to raise_error(Gemini::Client::Error, /malformed JSON/)
    end
  end

  # The "zoom in" path: re-analyze a clip of an ALREADY-uploaded file. The clip
  # window rides as video_metadata on the same file part — no re-upload — and
  # the offsets serialize as Duration strings ("Ns").
  describe "#analyze_segment" do
    let(:endpoint) { "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent" }
    let(:file_uri) { "https://generativelanguage.googleapis.com/v1beta/files/abc" }
    let(:response_schema) { { type: "OBJECT", properties: { findings: { type: "STRING" } } } }

    def stub_generate(text:)
      stub_request(:post, endpoint).to_return(
        status: 200, headers: json_headers,
        body: { candidates: [ { content: { parts: [ { text: text } ] } } ] }.to_json
      )
    end

    def analyze_segment(**overrides)
      client.analyze_segment(
        **{
          file_uri: file_uri,
          mime_type: "video/mp4",
          start_seconds: 72,
          end_seconds: 108,
          prompt: "Read the exact error text.",
          response_schema: response_schema
        }.merge(overrides)
      )
    end

    it "posts video_metadata offsets on the reused file part and parses the reply" do
      findings = { "findings" => "The banner reads: Save failed (E_TIMEOUT)." }
      stub_generate(text: findings.to_json)

      expect(analyze_segment).to eq(findings)

      # No upload request — the segment reuses the retained file by URI.
      expect(WebMock).not_to have_requested(:post, "https://generativelanguage.googleapis.com/upload/v1beta/files")

      expect(WebMock).to(have_requested(:post, endpoint).with do |req|
        parts = JSON.parse(req.body).dig("contents", 0, "parts")
        video_part = parts[0]

        video_part["file_data"] == { "file_uri" => file_uri, "mime_type" => "video/mp4" } &&
          video_part["video_metadata"] == { "start_offset" => "72s", "end_offset" => "108s" } &&
          parts[1] == { "text" => "Read the exact error text." }
      end)
    end

    it "defaults to full resolution (no mediaResolution) so small text is legible" do
      stub_generate(text: { "findings" => "ok" }.to_json)

      analyze_segment

      expect(WebMock).to(have_requested(:post, endpoint).with do |req|
        !JSON.parse(req.body).fetch("generationConfig").key?("mediaResolution")
      end)
    end

    it "maps a 429 to RateLimited like the whole-video path" do
      stub_request(:post, endpoint).to_return(
        status: 429, headers: json_headers,
        body: { error: { message: "Resource has been exhausted." } }.to_json
      )

      expect { analyze_segment }.to raise_error(Gemini::Client::RateLimited)
    end
  end
end
