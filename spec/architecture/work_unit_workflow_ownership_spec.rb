require "rails_helper"

# Each Workflow is owned by exactly one WorkUnit. The lock-safety argument
# (formal/SyrusModel/LockSafety.lean) depends on it: two units on one Workflow
# would let a lock escape through the second unit (Counterexamples.shared).
# Nothing in the schema enforces it -- work_units.workflow_id is not unique --
# so it holds only because WorkUnits::Launcher#instantiate is the one place
# that creates a unit and attaches a Workflow, and it attaches the Workflow its
# template has just created in the same transaction. Keep it that way: a new
# place that creates units or re-points one at a Workflow breaks the proof's
# assumption silently.
RSpec.describe "WorkUnit workflow ownership" do
  WRITERS = /WorkUnit\.(create|new|insert|upsert)|\bupdate!?\(workflow: |update_columns?\(.*\bworkflow(_id)?:|\.workflow(_id)? = (?!\S+\.)/
  ALLOWED = %w[
    app/services/work_units/launcher.rb
    app/services/work_engine/simulation/scenario_loader.rb
  ].freeze
  # Other models with a workflow association whose writes match the pattern.
  UNRELATED = %w[
    app/services/diff_review_versions/creator.rb
  ].freeze

  def offenders
    Dir.glob(Rails.root.join("{app,lib,plugins/*/app,plugins/*/lib}/**/*.rb")).filter_map do |file|
      relative = Pathname(file).relative_path_from(Rails.root).to_s
      next if ALLOWED.include?(relative) || UNRELATED.include?(relative)

      File.readlines(file).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(WRITERS)
      end.presence
    end.flatten
  end

  it "creates WorkUnits and attaches their Workflow only in the launcher" do
    expect(offenders).to be_empty, <<~MSG
      Only WorkUnits::Launcher#instantiate may create a WorkUnit or attach its
      Workflow (one unit per Workflow; see LockSafety.lean):
        #{offenders.join("\n  ")}
    MSG
  end

  # UnitReentry.lean: a finished unit may come back as blocked or queued
  # without its locks, which is safe only because WorkUnit#mark_running!,
  # which acquires every lock key first, is the one writer of a running unit.
  it "moves a WorkUnit's state only through WorkUnit's own transitions" do
    state_write = /\b(?i:\w*units?\w*)(\.\w+\([^)]*\))*\.(update|update!|update_columns|update_column|update_all)\(.*\bstate\b/
    expect('work_unit.update_columns(state: "running")').to match(state_write)
    expect('WorkUnit.where(id: ids).update_all(state: "queued")').to match(state_write)
    offenders = Dir.glob(Rails.root.join("{app,lib,plugins/*/app,plugins/*/lib}/**/*.rb")).filter_map do |file|
      relative = Pathname(file).relative_path_from(Rails.root).to_s
      next if relative == "app/models/work_unit.rb" || ALLOWED.include?(relative)

      File.readlines(file).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(state_write)
      end.presence
    end.flatten

    expect(offenders).to be_empty, <<~MSG
      Change a WorkUnit's state through WorkUnit#mark_running!, #block!,
      #unblock!, #mark_terminal! or #preempt!, not by writing the column:
        #{offenders.join("\n  ")}
    MSG
  end

  # Guard the guard: the launcher still does both, so the pattern still
  # matches the code it is meant to confine.
  it "still matches the launcher's own writes" do
    launcher = File.read(Rails.root.join("app/services/work_units/launcher.rb"))

    expect(launcher.lines.grep(WRITERS).size).to be >= 2
  end
end
