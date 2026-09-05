require "rails_helper"

RSpec.describe VideoWalkthroughs::Prompts::Context do
  def walkthrough(overrides = {})
    double(**{ id: 7, duration_seconds: 95 }.merge(overrides))
  end

  it "is a SHORT orientation that points the agent at its tools, not an analysis dump" do
    text = described_class.new(walkthrough: walkthrough).to_s

    # Orients + names the entry-point tool with the id baked in.
    expect(text).to include("get_walkthrough_analysis(walkthrough_id: 7)")
    expect(text).to include("read_walkthrough_frame(walkthrough_id: 7")
    expect(text).to include("analyze_walkthrough_segment(walkthrough_id: 7")
    # It explicitly does NOT carry the analysis itself — that comes back via the tool.
    expect(text).not_to include("## Issues found")
    expect(text).not_to include("## Narration transcript")
  end

  it "renders the duration in the header" do
    expect(described_class.new(walkthrough: walkthrough).to_s).to include("(1m35s)")
  end

  it "includes the operator's note when present, and omits the line otherwise" do
    expect(described_class.new(walkthrough: walkthrough, user_note: "watch Save").to_s)
      .to include("The operator's note with the video: watch Save")
    expect(described_class.new(walkthrough: walkthrough, user_note: "  ").to_s)
      .not_to include("The operator's note with the video:")
  end

  it "steers toward the Epic proposal flow and guards against inventing work" do
    text = described_class.new(walkthrough: walkthrough).to_s
    expect(text).to include("propose an Epic")
    expect(text).to match(/never guess text you can't read/i)
    expect(text).to match(/no real problems/i)
  end
end
