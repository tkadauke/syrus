require "rails_helper"

# Fake Gemini client for the segment tool: records analyze_segment / upload
# calls and returns a canned result, so no Net::HTTP stubbing is needed.
# Swapped in through the tool's client_factory seam (mirrors
# VideoWalkthroughAnalysisJob.client_factory).
class FakeSegmentClient
  attr_reader :analyze_calls, :upload_calls, :wait_calls, :resolve_calls

  # `raise_on_analyze` raises on analyze_segment. Pass a single error to raise on
  # every call, or an array to raise per-call in order (nil entries succeed) —
  # this models the tool's full-res → low-res retry ladder, where the first call
  # is RateLimited and the second (low-res) may succeed or re-fail.
  def initialize(result: { "findings" => "The banner reads: Save failed (E_TIMEOUT)." }, raise_on_analyze: nil)
    @result = result
    @raise_on_analyze = raise_on_analyze
    @analyze_calls = []
    @upload_calls = []
    @wait_calls = []
    @resolve_calls = 0
  end

  def resolve_video_model!
    @resolve_calls += 1
    "gemini-3.5-flash"
  end

  def analyze_segment(file_uri:, mime_type:, start_seconds:, end_seconds:, prompt:, response_schema:, media_resolution: :default)
    @analyze_calls << {
      file_uri: file_uri, mime_type: mime_type, start_seconds: start_seconds,
      end_seconds: end_seconds, prompt: prompt, response_schema: response_schema,
      media_resolution: media_resolution
    }

    if @raise_on_analyze.is_a?(Array)
      error = @raise_on_analyze[@analyze_calls.size - 1]
      raise error if error
    elsif @raise_on_analyze
      raise @raise_on_analyze
    end

    @result
  end

  def upload_file(io:, byte_size:, content_type:, display_name:)
    @upload_calls << { byte_size: byte_size, content_type: content_type, display_name: display_name, read: io.read }
    { "name" => "files/reup", "uri" => "https://generativelanguage.googleapis.com/v1beta/files/reup", "state" => "PROCESSING" }
  end

  def wait_until_active(name)
    @wait_calls << name
    { "name" => name, "uri" => "https://generativelanguage.googleapis.com/v1beta/files/reup", "state" => "ACTIVE" }
  end
end

RSpec.describe Mcp::Tools::AnalyzeWalkthroughSegmentTool do
  let(:user) { Factories.user(gemini_api_key: "gk-test") }
  let(:chat_session) { ChatSession.create!(user: user) }
  let(:fake_client) { FakeSegmentClient.new }

  let(:analysis) do
    { "summary" => "s", "issues" => [ { "title" => "Save fails", "severity" => "high" } ], "open_questions" => [] }
  end

  around do |example|
    original = described_class.client_factory
    begin
      example.run
    ensure
      described_class.client_factory = original
    end
  end

  before do
    described_class.client_factory = ->(api_key:) { @factory_key = api_key; fake_client }
  end

  def create_walkthrough(**attrs)
    ChatVideoWalkthrough.new({
      chat_session: chat_session, user: user, content_type: "video/webm",
      byte_size: 10, duration_seconds: 95, title: "Checkout run", state: "analyzed",
      analysis: analysis, gemini_file_uri: "https://generativelanguage.googleapis.com/v1beta/files/orig",
      gemini_file_active_at: Time.current
    }.merge(attrs)).tap do |w|
      w.file.attach(io: StringIO.new("webm-bytes"), filename: "walkthrough.webm", content_type: "video/webm")
      w.save!
    end
  end

  def server
    MCP::Server.new(name: "syrus-chat-sidecar", tools: [ described_class ], server_context: { chat_session: chat_session })
  end

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "analyze_walkthrough_segment", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  describe "happy path (retained file, fresh)" do
    it "re-analyzes the range against the retained file and returns the fine detail" do
      walkthrough = create_walkthrough

      response = call_tool(walkthrough_id: walkthrough.id, start: "01:12", end: "01:30", focus: "the exact error text")

      expect(response[:result][:isError]).to be_falsey
      body = payload(response)
      expect(body[:walkthrough_id]).to eq(walkthrough.id)
      expect(body[:range]).to eq("1:12–1:30")
      expect(body[:analysis]).to eq(fake_client.instance_variable_get(:@result).transform_keys(&:to_sym))

      # Full resolution, correct window, retained file reused (no re-upload).
      expect(fake_client.upload_calls).to be_empty
      expect(fake_client.resolve_calls).to eq(1)
      call = fake_client.analyze_calls.first
      expect(call).to include(
        file_uri: "https://generativelanguage.googleapis.com/v1beta/files/orig",
        mime_type: "video/webm", start_seconds: 72, end_seconds: 90, media_resolution: :default
      )
      expect(call[:prompt]).to include("the exact error text")
      expect(@factory_key).to eq("gk-test")
    end

    it "sends the mime of the UPLOADED file on the retained path, not the drifted post-transcode content_type" do
      # After the initial analysis transcodes the stored blob to mp4, the row's
      # content_type drifts to video/mp4 while the RETAINED Gemini upload is
      # still the pre-transcode webm. The retained-file zoom must reference the
      # uploaded mime (recorded in gemini_file_content_type), not content_type.
      walkthrough = create_walkthrough(content_type: "video/mp4", gemini_file_content_type: "video/webm")

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "the exact error text")

      expect(response[:result][:isError]).to be_falsey
      expect(fake_client.upload_calls).to be_empty
      expect(fake_client.analyze_calls.first).to include(
        file_uri: "https://generativelanguage.googleapis.com/v1beta/files/orig",
        mime_type: "video/webm"
      )
    end
  end

  describe "clamping" do
    it "caps end at the video duration" do
      walkthrough = create_walkthrough(duration_seconds: 95)

      call_tool(walkthrough_id: walkthrough.id, start: "01:00", end: "05:00", focus: "clicks")

      call = fake_client.analyze_calls.first
      expect(call[:start_seconds]).to eq(60)
      expect(call[:end_seconds]).to eq(95)
    end

    it "caps an over-long window to the segment length limit and notes the truncation" do
      # A full-res re-analysis of a huge window blows the free-tier per-minute
      # token budget; the tool clamps the clip to MAX_SEGMENT_SECONDS (4 min).
      walkthrough = create_walkthrough(duration_seconds: 15 * 60)

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:00", end: "15:00", focus: "everything")

      expect(response[:result][:isError]).to be_falsey
      call = fake_client.analyze_calls.first
      expect(call[:start_seconds]).to eq(0)
      expect(call[:end_seconds]).to eq(described_class::MAX_SEGMENT_SECONDS)
      expect(call[:end_seconds]).to eq(240)

      body = payload(response)
      expect(body[:range]).to eq("0:00–4:00")
      expect(body[:note]).to include("truncated")
      expect(body[:note]).to include("4-minute")
    end

    it "leaves a within-limit window untouched (no truncation note)" do
      walkthrough = create_walkthrough(duration_seconds: 15 * 60)

      response = call_tool(walkthrough_id: walkthrough.id, start: "01:00", end: "03:00", focus: "clicks")

      call = fake_client.analyze_calls.first
      expect(call[:start_seconds]).to eq(60)
      expect(call[:end_seconds]).to eq(180)
      expect(payload(response)).not_to have_key(:note)
    end

    it "rejects an empty or inverted window" do
      walkthrough = create_walkthrough

      response = call_tool(walkthrough_id: walkthrough.id, start: "01:30", end: "01:00", focus: "clicks")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("end must be after start")
      expect(fake_client.analyze_calls).to be_empty
    end

    it "rejects unparseable timestamps" do
      walkthrough = create_walkthrough

      response = call_tool(walkthrough_id: walkthrough.id, start: "banana", end: "01:00", focus: "clicks")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("mm:ss or whole seconds")
    end
  end

  describe "expired / missing file handling" do
    it "re-uploads the stored blob when the retained file is past retention" do
      walkthrough = create_walkthrough(gemini_file_active_at: 3.days.ago)

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "the sequence of clicks")

      expect(response[:result][:isError]).to be_falsey
      expect(fake_client.upload_calls.size).to eq(1)
      expect(fake_client.upload_calls.first).to include(content_type: "video/webm", read: "webm-bytes")
      # The tool persists the fresh upload and analyzes against it.
      expect(walkthrough.reload.gemini_file_uri).to eq("https://generativelanguage.googleapis.com/v1beta/files/reup")
      expect(fake_client.analyze_calls.first[:file_uri]).to eq("https://generativelanguage.googleapis.com/v1beta/files/reup")
    end

    it "re-uploads with the STORED BLOB's content_type, not the row's drifted content_type" do
      # Post-transcode the row's content_type is video/mp4, but here the stored
      # blob is a webm (drift / a not-yet-transcoded original). The re-upload
      # must describe the bytes it actually sends — the blob's content_type.
      walkthrough = create_walkthrough(gemini_file_active_at: 3.days.ago, content_type: "video/mp4")

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "clicks")

      expect(response[:result][:isError]).to be_falsey
      expect(fake_client.upload_calls.first).to include(content_type: "video/webm")
      expect(fake_client.analyze_calls.first[:mime_type]).to eq("video/webm")
      # The re-uploaded mime is stamped for any later retained-file pass.
      expect(walkthrough.reload.gemini_file_content_type).to eq("video/webm")
    end

    it "returns a clean tool error when the stored blob cannot be read (pruned/unreadable)" do
      walkthrough = create_walkthrough(gemini_file_active_at: 3.days.ago)
      # Delete the physical file but keep the attachment + blob rows: file is
      # still 'attached' and blob.content_type is readable, but download raises —
      # exactly the ActiveStorage failure that used to escape the rescues.
      walkthrough.file.blob.service.delete(walkthrough.file.blob.key)

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "clicks")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("Could not read the stored video")
      expect(fake_client.upload_calls).to be_empty
      expect(fake_client.analyze_calls).to be_empty
    end

    it "reports the video expired when past retention and the blob is gone (unattached)" do
      walkthrough = create_walkthrough(gemini_file_active_at: 3.days.ago)
      walkthrough.file.purge

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "clicks")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("expired")
      expect(fake_client.analyze_calls).to be_empty
    end
  end

  describe "scoping + state guards" do
    it "does not find a walkthrough from another chat" do
      other = ChatSession.create!(user: user)
      walkthrough = create_walkthrough(chat_session: other)

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "clicks")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("not found in this chat")
    end

    it "rejects a walkthrough with no completed analysis" do
      walkthrough = create_walkthrough(state: "uploaded", analysis: nil)

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "clicks")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("no completed analysis")
    end

    it "maps Gemini rate limiting to a retry-friendly tool error" do
      allow(fake_client).to receive(:analyze_segment).and_raise(Gemini::Client::RateLimited.new("429"))
      walkthrough = create_walkthrough

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "clicks")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("quota")
    end
  end

  # Graceful degradation mirroring the whole-video analysis job: a full-res
  # segment that blows the free-tier per-minute token window retries ONCE at
  # low resolution before surfacing the quota error. Full res stays the default
  # (LOW garbles small text — the whole point of the zoom).
  describe "rate-limit low-resolution fallback" do
    it "retries the segment once at low resolution when the full-res pass is rate-limited" do
      low_res_client = FakeSegmentClient.new(
        result: { "findings" => "low-res answer" },
        raise_on_analyze: [ Gemini::Client::RateLimited.new("429"), nil ]
      )
      described_class.client_factory = ->(api_key:) { low_res_client }
      walkthrough = create_walkthrough

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "clicks")

      expect(response[:result][:isError]).to be_falsey
      expect(low_res_client.analyze_calls.size).to eq(2)
      expect(low_res_client.analyze_calls[0][:media_resolution]).to eq(:default)
      expect(low_res_client.analyze_calls[1][:media_resolution]).to eq(:low)
      # Same window on both attempts — only the resolution degrades.
      expect(low_res_client.analyze_calls[1]).to include(start_seconds: 10, end_seconds: 40)
      expect(payload(response)[:analysis]).to eq(findings: "low-res answer")
    end

    it "surfaces the quota error only after the low-res retry also rate-limits" do
      exhausted_client = FakeSegmentClient.new(
        raise_on_analyze: [ Gemini::Client::RateLimited.new("429"), Gemini::Client::RateLimited.new("429") ]
      )
      described_class.client_factory = ->(api_key:) { exhausted_client }
      walkthrough = create_walkthrough

      response = call_tool(walkthrough_id: walkthrough.id, start: "00:10", end: "00:40", focus: "clicks")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("quota")
      expect(exhausted_client.analyze_calls.size).to eq(2)
      expect(exhausted_client.analyze_calls[1][:media_resolution]).to eq(:low)
    end
  end

  describe "registration" do
    it "is advertised as a deferred chat tool" do
      expect(Mcp::Sidecar.chat_tool_names(tier: :deferred)).to include("analyze_walkthrough_segment")
      expect(Mcp::Sidecar.chat_tool_names(tier: :essential)).not_to include("analyze_walkthrough_segment")
    end
  end
end
