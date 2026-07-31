require "rails_helper"

RSpec.describe Mcp::Tools::GetWalkthroughAnalysisTool do
  let(:user) { Factories.user(gemini_api_key: "gk-test") }
  let(:chat_session) { ChatSession.create!(user: user) }

  let(:analysis) do
    {
      "summary" => "Checkout works; Save fails silently.",
      "sections" => [ { "start" => "00:00", "end" => "00:40", "title" => "Checkout", "summary" => "pays" } ],
      "issues" => [
        {
          "title" => "Save button does nothing", "severity" => "high", "surface" => "settings",
          "timestamp" => "01:12", "description" => "no feedback",
          "unreadable_text" => "the code in the red toast", "needs_closer_look" => true
        },
        { "title" => "Low contrast", "severity" => "low", "timestamp" => "00:20", "description" => "gray on gray" }
      ],
      "open_questions" => [ "Should drafts autosave?" ],
      "transcript" => [ { "timestamp" => "00:03", "text" => "adding a widget" } ]
    }
  end

  def create_walkthrough(**attrs)
    ChatVideoWalkthrough.new({
      chat_session: chat_session, user: user, content_type: "video/mp4",
      byte_size: 10, duration_seconds: 95, title: "Checkout run", state: "analyzed", analysis: analysis
    }.merge(attrs)).tap do |w|
      w.file.attach(io: StringIO.new("mp4-bytes"), filename: "walkthrough.mp4", content_type: "video/mp4")
      w.save!
    end
  end

  def server
    MCP::Server.new(name: "syrus-chat-sidecar", tools: [ described_class ], server_context: { chat_session: chat_session })
  end

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call",
                               params: { name: "get_walkthrough_analysis", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def frame(seconds:, label:, jpeg:)
    Gemini::FrameExtractor::Frame.new(seconds: seconds, label: label, jpeg: jpeg)
  end

  describe "happy path" do
    it "returns the report text plus a labeled image block per extracted frame" do
      allow(Gemini::FrameExtractor).to receive(:extract).and_return([
        frame(seconds: 72, label: "Save button does nothing", jpeg: "jpeg-A")
      ])
      walkthrough = create_walkthrough

      content = call_tool(walkthrough_id: walkthrough.id).dig(:result, :content)

      text = content.select { |b| b[:type] == "text" }.map { |b| b[:text] }.join("\n")
      images = content.select { |b| b[:type] == "image" }

      expect(text).to include("## Session summary")
      expect(text).to include("## Issues found (2)")
      expect(text).to include("Save button does nothing")
      # Flagged issue's frame WAS attached → read-off-the-attached-screenshot line.
      expect(text).to include("read the exact text off the screenshot attached below: the code in the red toast")
      expect(text).to include("Screenshot — Save button does nothing (at 1:12):")

      expect(images.size).to eq(1)
      expect(images.first[:mimeType]).to eq("image/jpeg")
      expect(images.first[:data]).to eq(Base64.strict_encode64("jpeg-A"))
    end

    it "prioritizes flagged frames at top JPEG quality" do
      captured = nil
      allow(Gemini::FrameExtractor).to receive(:extract) do |video_path:, timestamps:, **|
        captured = timestamps
        []
      end
      call_tool(walkthrough_id: create_walkthrough.id)

      flagged = captured.find { |e| e[:label] == "Save button does nothing" }
      plain = captured.find { |e| e[:label] == "Low contrast" }
      expect(flagged).to include(flagged: true, jpeg_quality: Gemini::FrameExtractor::HIGH_JPEG_QUALITY)
      expect(plain).to include(flagged: false, jpeg_quality: Gemini::FrameExtractor::JPEG_QUALITY)
    end
  end

  describe "degradation" do
    it "returns text only (no images) when frame extraction yields nothing" do
      allow(Gemini::FrameExtractor).to receive(:extract).and_return([])
      content = call_tool(walkthrough_id: create_walkthrough.id).dig(:result, :content)

      expect(content.select { |b| b[:type] == "image" }).to be_empty
      text = content.first[:text]
      expect(text).to include("Save button does nothing")
      # Unattached flagged issue is steered to the on-demand fetch, not a screenshot.
      expect(text).to include("call read_walkthrough_frame")
    end

    it "returns text only when the stored video was pruned" do
      allow(Gemini::FrameExtractor).to receive(:extract).and_call_original
      walkthrough = create_walkthrough
      walkthrough.file.purge

      content = call_tool(walkthrough_id: walkthrough.id).dig(:result, :content)
      expect(content.select { |b| b[:type] == "image" }).to be_empty
      expect(content.first[:text]).to include("## Issues found")
    end

    it "degrades to text when extraction raises" do
      allow(Gemini::FrameExtractor).to receive(:extract).and_raise(RuntimeError.new("ffmpeg exploded"))
      content = call_tool(walkthrough_id: create_walkthrough.id).dig(:result, :content)
      expect(content.select { |b| b[:type] == "image" }).to be_empty
      expect(content.first[:text]).to include("Save button does nothing")
    end
  end

  describe "errors" do
    it "errors when the walkthrough is not in this chat" do
      result = call_tool(walkthrough_id: 999_999)
      expect(result.dig(:result, :isError)).to be(true)
      expect(result.dig(:result, :content).first[:text]).to match(/not found/)
    end

    it "errors when the walkthrough has no analysis yet" do
      walkthrough = create_walkthrough(state: "analyzing", analysis: nil)
      result = call_tool(walkthrough_id: walkthrough.id)
      expect(result.dig(:result, :isError)).to be(true)
      expect(result.dig(:result, :content).first[:text]).to match(/no analysis yet/)
    end
  end
end
