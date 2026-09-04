require "rails_helper"

# Every Problem a step declares must be a real Problem::Kind.
#
# The failure this prevents is specific and has already happened once, in the
# other direction: RunFailureClassifier kept a list of patterns describing the
# messages merge-train steps raise, and the steps' wording drifted away from
# it. Nothing failed -- the patterns simply stopped matching, and seven real
# failure modes silently degraded to `application_error`, which routed a train
# that needed rebuilding into "give up, require operator re-approval".
#
# A declared code is checkable in a way a pattern list is not, so check it.
RSpec.describe "declared step problems" do
  # `fail_with!(:code, ...)` and `problem_code :code`, wherever they appear.
  DECLARATION = /(?:fail_with!\(|problem_code )[:\s]*:([a-z0-9_]+)/
  SOURCES = Dir[Rails.root.join("app/services/steps/**/*.rb")] +
            Dir[Rails.root.join("plugins/*/app/services/steps/**/*.rb")] +
            Dir[Rails.root.join("plugins/*/lib/**/steps/**/*.rb")]

  it "names a code the shared vocabulary knows" do
    unknown = SOURCES.flat_map do |path|
      File.read(path).scan(DECLARATION).flatten.uniq.filter_map do |code|
        "#{Pathname(path).relative_path_from(Rails.root)}: #{code}" unless Problem::Kind.exists?(code)
      end
    end

    expect(unknown).to be_empty,
      "these step failures declare a Problem code that is not in Problem::Kind:\n  #{unknown.join("\n  ")}"
  end

  it "actually finds declarations, so a rename cannot quietly empty this check" do
    found = SOURCES.flat_map { |path| File.read(path).scan(DECLARATION).flatten }

    expect(found).to include("merge_train_rebuild_required", "merge_train_rebase_conflict", "grader_failure")
  end
end
