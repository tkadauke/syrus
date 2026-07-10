require "rails_helper"

RSpec.describe CoverageAnalysis::DiffAnnotator do
  HIT_MAP = {
    "app/models/user.rb" => {
      "1" => 5,   # covered
      "2" => 0,   # uncovered (executable but no hits)
      "3" => 3    # covered
      # line 4 is absent → not_executable
    }
  }.freeze

  SAMPLE_DIFF = <<~DIFF
    diff --git a/app/models/user.rb b/app/models/user.rb
    index abc..def 100644
    --- a/app/models/user.rb
    +++ b/app/models/user.rb
    @@ -0,0 +1,4 @@
    +line one
    +line two
    +line three
    +line four
  DIFF

  it "annotates added lines correctly" do
    annotations, _pr_delta = described_class.annotate(SAMPLE_DIFF, HIT_MAP)
    file_ann = annotations["app/models/user.rb"]

    expect(file_ann["1"]).to eq("covered")
    expect(file_ann["2"]).to eq("uncovered")
    expect(file_ann["3"]).to eq("covered")
    expect(file_ann["4"]).to eq("not_executable")
  end

  it "computes pr_delta covered/total counts" do
    _annotations, pr_delta = described_class.annotate(SAMPLE_DIFF, HIT_MAP)

    expect(pr_delta["covered"]).to eq(2)
    expect(pr_delta["total"]).to eq(3)  # line 4 is not_executable, not counted
    expect(pr_delta["pct"]).to be_within(0.01).of(66.67)
    expect(pr_delta["uncovered_files"]).to eq(["app/models/user.rb"])
  end

  it "returns empty annotations for an empty diff" do
    annotations, pr_delta = described_class.annotate("", HIT_MAP)
    expect(annotations).to be_empty
    expect(pr_delta["total"]).to eq(0)
    expect(pr_delta["pct"]).to be_nil
  end

  it "handles diffs with no added lines" do
    diff = <<~DIFF
      diff --git a/app/models/user.rb b/app/models/user.rb
      index abc..def 100644
      --- a/app/models/user.rb
      +++ b/app/models/user.rb
      @@ -1,2 +1,0 @@
      -removed one
      -removed two
    DIFF

    annotations, pr_delta = described_class.annotate(diff, HIT_MAP)
    expect(annotations).to be_empty
    expect(pr_delta["total"]).to eq(0)
  end
end
