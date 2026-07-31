require "rails_helper"

RSpec.describe Mcp::Tools::ReadWalkthroughFrameTool do
  let(:user) { Factories.user(gemini_api_key: "gk-test") }
  let(:chat_session) { ChatSession.create!(user: user) }

  let(:analysis) do
    { "summary" => "s", "issues" => [ { "title" => "Save fails", "severity" => "high" } ], "open_questions" => [] }
  end

  def create_walkthrough(**attrs)
    ChatVideoWalkthrough.new({
      chat_session: chat_session, user: user, content_type: "video/mp4",
      byte_size: 10, duration_seconds: 95, title: "Checkout run", state: "analyzed",
      analysis: analysis
    }.merge(attrs)).tap do |w|
      w.file.attach(io: StringIO.new("mp4-bytes"), filename: "walkthrough.mp4", content_type: "video/mp4")
      w.save!
    end
  end

  def server
    MCP::Server.new(name: "syrus-chat-sidecar", tools: [ described_class ], server_context: { chat_session: chat_session })
  end

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_walkthrough_frame", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def frame(seconds:, jpeg:)
    Gemini::FrameExtractor::Frame.new(seconds: seconds, label: "x", jpeg: jpeg)
  end

  # Stub extraction to record the timestamps it was handed and return a canned
  # frame — no ffmpeg needed. The tool still downloads the blob to a tempfile
  # before this runs, exercising the real ActiveStorage read path.
  def stub_extract(return_frames)
    captured = { timestamps: nil, video_bytes: nil }
    allow(Gemini::FrameExtractor).to receive(:extract) do |video_path:, timestamps:, **|
      captured[:timestamps] = timestamps
      captured[:video_bytes] = File.binread(video_path)
      Array(return_frames)
    end
    captured
  end

  describe "happy path" do
    it "returns the frame as a native MCP image content block the agent sees directly, plus an OCR instruction" do
      jpeg = "JPEGDATA" * 500 # ~4KB, a reasonably-sized still
      captured = stub_extract([ frame(seconds: 42, jpeg: jpeg) ])
      walkthrough = create_walkthrough

      response = call_tool(walkthrough_id: walkthrough.id, timestamp: "00:42")

      expect(response[:result][:isError]).to be_falsey
      content = response[:result][:content]

      image = content.find { |block| block[:type] == "image" }
      expect(image).to be_present
      expect(image[:mimeType]).to eq("image/jpeg")
      expect(image[:data]).to be_present
      # Round-trips to the exact bytes, and is a non-trivial image payload.
      expect(Base64.strict_decode64(image[:data])).to eq(jpeg)
      expect(image[:data].bytesize).to be > 1000

      text = content.find { |block| block[:type] == "text" }
      expect(text[:text]).to include("walkthrough ##{walkthrough.id} at 0:42")
      expect(text[:text]).to match(/don't guess/i)

      # Extracted the requested second from the stored blob.
      expect(captured[:timestamps].first).to include(seconds: 42)
      expect(captured[:video_bytes]).to eq("mp4-bytes")
    end
  end

  describe "clamping" do
    it "clamps a timestamp past the end to the video's last whole second" do
      captured = stub_extract([ frame(seconds: 94, jpeg: "j") ])
      walkthrough = create_walkthrough(duration_seconds: 95)

      call_tool(walkthrough_id: walkthrough.id, timestamp: "05:00")

      # duration - 1 (a frame exactly at the duration may not exist).
      expect(captured[:timestamps].first[:seconds]).to eq(94)
    end

    it "leaves an in-range timestamp untouched" do
      captured = stub_extract([ frame(seconds: 30, jpeg: "j") ])
      walkthrough = create_walkthrough(duration_seconds: 95)

      call_tool(walkthrough_id: walkthrough.id, timestamp: "00:30")

      expect(captured[:timestamps].first[:seconds]).to eq(30)
    end

    it "rejects an unparseable timestamp before touching the video" do
      stub_extract([])
      walkthrough = create_walkthrough

      response = call_tool(walkthrough_id: walkthrough.id, timestamp: "banana")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("mm:ss or whole seconds")
      expect(Gemini::FrameExtractor).not_to have_received(:extract)
    end
  end

  # webm MediaRecorder blobs commonly report no measurable length, so the client
  # omits duration and the row persists nil. With no known duration we can't cap
  # a past-end timestamp, and the tool must not clamp against a bogus bound or
  # blame ffmpeg for what is really a past-the-end seek.
  describe "unknown (nil) duration" do
    it "does not clamp — passes the raw requested second straight to extraction" do
      captured = stub_extract([ frame(seconds: 300, jpeg: "j") ])
      walkthrough = create_walkthrough(duration_seconds: nil)

      call_tool(walkthrough_id: walkthrough.id, timestamp: "05:00")

      # No upper bound is known, so 300s reaches ffmpeg unchanged (not clamped).
      expect(captured[:timestamps].first[:seconds]).to eq(300)
    end

    it "returns an honest 'may be past the end' error (not the ffmpeg/corrupt guess) on a frameless grab" do
      stub_extract([]) # ffmpeg produced nothing
      walkthrough = create_walkthrough(duration_seconds: nil)

      response = call_tool(walkthrough_id: walkthrough.id, timestamp: "05:00")

      expect(response[:result][:isError]).to be(true)
      text = response[:result][:content].first[:text]
      expect(text).to include("past its end")
      expect(text).to include("5:00") # names the requested time
      expect(text).to include("duration is unknown")
    end
  end

  describe "expired / unreadable video" do
    it "reports the video expired when the stored blob is gone (unattached)" do
      allow(Gemini::FrameExtractor).to receive(:extract)
      walkthrough = create_walkthrough
      walkthrough.file.purge

      response = call_tool(walkthrough_id: walkthrough.id, timestamp: "00:10")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("expired")
      expect(Gemini::FrameExtractor).not_to have_received(:extract)
    end

    it "returns a clean tool error when the stored blob can't be read (pruned/unreadable)" do
      allow(Gemini::FrameExtractor).to receive(:extract)
      walkthrough = create_walkthrough
      # Attachment + blob rows remain (still 'attached'), but the physical file is
      # gone, so download raises — exactly the ActiveStorage failure the tool maps.
      walkthrough.file.blob.service.delete(walkthrough.file.blob.key)

      response = call_tool(walkthrough_id: walkthrough.id, timestamp: "00:10")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("Couldn't read the stored video")
      expect(Gemini::FrameExtractor).not_to have_received(:extract)
    end

    it "returns a capture error when ffmpeg produces no frame (extract returns [])" do
      stub_extract([])
      walkthrough = create_walkthrough

      response = call_tool(walkthrough_id: walkthrough.id, timestamp: "00:10")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("Couldn't capture a screenshot")
    end
  end

  describe "scoping" do
    it "does not find a walkthrough from another chat" do
      stub_extract([ frame(seconds: 10, jpeg: "j") ])
      other = ChatSession.create!(user: user)
      walkthrough = create_walkthrough(chat_session: other)

      response = call_tool(walkthrough_id: walkthrough.id, timestamp: "00:10")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("not found in this chat")
      expect(Gemini::FrameExtractor).not_to have_received(:extract)
    end
  end

  describe "registration" do
    it "is advertised as a deferred chat tool, not an essential one" do
      expect(Mcp::Sidecar.chat_tool_names(tier: :deferred)).to include("read_walkthrough_frame")
      expect(Mcp::Sidecar.chat_tool_names(tier: :essential)).not_to include("read_walkthrough_frame")
    end
  end
end
