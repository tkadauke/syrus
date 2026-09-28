require "rails_helper"

RSpec.describe CognitiveCoverage::LineProjector do
  class FakeCognitiveCoverageGitRunner
    def initialize(outputs)
      @outputs = outputs
    end

    def run(*args, chdir:)
      @outputs.fetch(args)
    end
  end

  it "projects an unchanged historical line through inserted lines" do
    runner = FakeCognitiveCoverageGitRunner.new(
      [ "diff", "--unified=0", "oldsha", "newsha", "--", "app/models/widget.rb" ] =>
        "@@ -1,0 +2,1 @@\n+inserted\n"
    )
    projector = described_class.new(workspace_path: "/repo", target_sha: "newsha", git_runner: runner)
    engagement = CognitiveCoverage::Engagement.new(
      path: "app/models/widget.rb",
      line_number: 2,
      engaged_at: Time.zone.parse("2026-01-01"),
      source: "diff_review_comment",
      source_sha: "oldsha"
    )

    expect(projector.project(engagement).line_number).to eq(3)
  end

  it "drops an engagement when the source line is inside an ambiguous changed hunk" do
    runner = FakeCognitiveCoverageGitRunner.new(
      [ "diff", "--unified=0", "oldsha", "newsha", "--", "app/models/widget.rb" ] =>
        "@@ -2,2 +2,3 @@\n-old\n-other\n+new\n+other\n+extra\n"
    )
    projector = described_class.new(workspace_path: "/repo", target_sha: "newsha", git_runner: runner)
    engagement = CognitiveCoverage::Engagement.new(
      path: "app/models/widget.rb",
      line_number: 2,
      engaged_at: Time.zone.parse("2026-01-01"),
      source: "diff_review_comment",
      source_sha: "oldsha"
    )

    expect(projector.project(engagement)).to be_nil
  end
end
