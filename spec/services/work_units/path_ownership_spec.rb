require "rails_helper"

RSpec.describe WorkUnits::PathOwnership do
  it "treats every registered path as WorkUnit-owned" do
    described_class::PATH_GROUPS.each do |path, group|
      result = described_class.for(path)

      expect(result).to be_work_unit
      expect(result).not_to be_legacy
      expect(result.group).to eq(group)
    end
  end

  it "groups scheduler, landing, and reconciler paths for diagnostics" do
    expect(described_class.for("manual_pause").group).to eq("scheduler")
    expect(described_class.for("merge_train").group).to eq("landing")
    expect(described_class.for("stale_runs").group).to eq("reconciler")
  end

  it "raises for unknown paths instead of silently choosing an owner" do
    expect { described_class.for("new_unregistered_path") }
      .to raise_error(KeyError, /unknown work unit ownership path/)
  end
end
