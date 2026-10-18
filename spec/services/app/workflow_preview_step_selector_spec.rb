require "rails_helper"

RSpec.describe App::WorkflowPreviewStepSelector do
  def step(id, status, name: "Step #{id}")
    { id: id, display_name: name, display_status: status }
  end

  it "keeps the first, running anchor, nearest queued steps, and workflow order" do
    rows = described_class.new([
      step(1, "succeeded"), step(2, "succeeded"), step(3, "running"),
      step(4, "queued"), step(5, "queued")
    ], active: true).call

    expect(rows.filter_map { |row| row[:id] }).to eq([ 1, 2, 3, 4, 5 ])
  end

  it "marks a trailing omitted range without counting the ellipsis as a step" do
    steps = [ step(1, "succeeded"), step(2, "running") ] +
      (3..8).map { |id| step(id, "failed") } + [ step(9, "queued") ]

    rows = described_class.new(steps, active: true).call

    expect(rows.count { |row| row[:id] }).to eq(7)
    expect(rows.last).to eq(ellipsis: true)
  end

  it "retains the newest seven interesting steps and inserts every omitted range" do
    steps = (1..12).map { |id| step(id, id.between?(2, 10) ? "failed" : "succeeded") }
    rows = described_class.new(steps, active: false).call

    expect(rows.filter_map { |row| row[:id] }).to eq([ 1, 6, 7, 8, 9, 10, 12 ])
    expect(rows.count { |row| row[:ellipsis] }).to eq(2)
  end

  it "preserves duplicate display names and the literal final cancelled step" do
    rows = described_class.new([
      step(1, "succeeded"),
      step(2, "failed", name: "Grade Loop"),
      step(3, "succeeded", name: "Grade Loop"),
      step(4, "cancelled")
    ], active: false).call

    expect(rows.filter_map { |row| row[:id] }).to eq([ 1, 2, 3, 4 ])
    expect(rows.filter_map { |row| row[:display_name] }).to include("Grade Loop", "Grade Loop")
  end
end
