require "rails_helper"

RSpec.describe VideoWalkthroughs::Prompts::Report do
  def walkthrough(overrides = {})
    defaults = {
      id: 7,
      duration_seconds: 95,
      analysis_summary: "Tested checkout; Save fails silently.",
      analysis_sections: [
        { "start" => "00:00", "end" => "00:40", "title" => "Checkout", "summary" => "Adds items and pays." },
        { "start" => "00:40", "end" => "01:35", "title" => "Settings", "summary" => "Tries to save preferences." }
      ],
      analysis_issues: [
        {
          "title" => "Save button does nothing", "severity" => "high", "surface" => "settings",
          "timestamp" => "01:12", "description" => "Clicking Save shows no feedback.",
          "transcript_evidence" => "nothing happens when I hit save",
          "visual_evidence" => "the spinner never appears",
          "user_flagged" => true, "needs_closer_look" => true,
          "unreadable_text" => "the error code in the red toast, bottom-right"
        },
        {
          "title" => "Header contrast is low", "severity" => "low", "surface" => "header",
          "timestamp" => "00:20", "description" => "Gray on gray."
        }
      ],
      analysis_open_questions: [ "Should drafts autosave?" ],
      analysis_transcript: [
        { "timestamp" => "00:03", "text" => "Okay, adding a widget to the cart." },
        { "timestamp" => "01:12", "text" => "nothing happens when I hit save" }
      ]
    }
    double(**defaults.merge(overrides))
  end

  it "renders summary, sections, issues with fields, transcript, and open questions" do
    text = described_class.new(walkthrough: walkthrough).to_s

    expect(text).to include("## Session summary")
    expect(text).to include("## Sections")
    expect(text).to include("**Checkout** (00:00–00:40) — Adds items and pays.")

    expect(text).to include("## Issues found (2)")
    expect(text).to include("**Save button does nothing** (high, settings, at 01:12, user-flagged, needs a closer look)")
    expect(text).to include("The user said: \"nothing happens when I hit save\"")
    expect(text).to include("On screen: the spinner never appears")

    expect(text).to include("## Narration transcript")
    expect(text).to include("[00:03] Okay, adding a widget to the cart.")
    expect(text).to include("## Open questions from the analysis")
  end

  it "orders issues high → medium → low" do
    text = described_class.new(walkthrough: walkthrough).to_s
    expect(text.index("Save button does nothing")).to be < text.index("Header contrast is low")
  end

  # The Save issue at 01:12 with title "Save button does nothing".
  def save_issue_key
    described_class.attachment_key(seconds: 72, title: "Save button does nothing")
  end

  it "tells the agent to read the ATTACHED screenshot when this issue's frame rode along" do
    text = described_class.new(walkthrough: walkthrough, attached_issue_keys: [ save_issue_key ]).to_s
    expect(text).to include("read the exact text off the screenshot attached below: the error code in the red toast, bottom-right")
    expect(text).not_to include("call read_walkthrough_frame(walkthrough_id: 7, timestamp: 01:12)")
  end

  it "points an UNATTACHED flagged issue at read_walkthrough_frame, never claiming a screenshot" do
    text = described_class.new(walkthrough: walkthrough).to_s
    expect(text).to include("call read_walkthrough_frame(walkthrough_id: 7, timestamp: 01:12)")
    expect(text).not_to include("attached below")
  end

  it "carries the never-invent OCR guardrail whenever there is flagged text" do
    text = described_class.new(walkthrough: walkthrough).to_s
    expect(text).to include("## Reading small on-screen text")
    expect(text).to match(/NEVER invent/)
  end

  it "omits the OCR guidance when no issue has unreadable text and nothing is attached" do
    plain = walkthrough(analysis_issues: [ { "title" => "x", "severity" => "low", "description" => "y" } ])
    text = described_class.new(walkthrough: plain).to_s
    expect(text).not_to include("## Reading small on-screen text")
  end

  it "renders an empty-issues walkthrough without inventing problems" do
    empty = walkthrough(analysis_issues: [], analysis_open_questions: [])
    text = described_class.new(walkthrough: empty).to_s
    expect(text).to include("## Issues found\n(none")
  end
end
