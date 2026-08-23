require "rails_helper"

RSpec.describe WorkUnits::PathOwnership do
  def set_feature(slug, enabled)
    Feature.find_or_create_by!(slug: slug) do |feature|
      feature.category = "Operations"
      feature.name = slug.to_s.humanize
    end.update!(enabled: enabled)
  end

  it "keeps scheduler paths legacy-owned while the scheduler gate is disabled" do
    set_feature("work_units_scheduler", false)

    result = described_class.for("retry")

    expect(result).to be_legacy
    expect(result).not_to be_work_unit
    expect(result.gate).to eq("work_units_scheduler")
  end

  it "moves scheduler paths to work-unit ownership when the scheduler gate is enabled" do
    set_feature("work_units_scheduler", true)

    result = described_class.for(:manual_pause)

    expect(result).to be_work_unit
    expect(result).not_to be_legacy
    expect(result.gate).to eq("work_units_scheduler")
  end

  it "gates landing paths separately from scheduler paths" do
    set_feature("work_units_scheduler", true)
    set_feature("work_units_landing", false)

    expect(described_class.for("retry")).to be_work_unit
    expect(described_class.for("auto_retry_backoff")).to be_work_unit
    expect(described_class.for("merge_train")).to be_legacy

    set_feature("work_units_landing", true)

    expect(described_class.for("merge_train")).to be_work_unit
  end

  it "gates reconciler paths separately from scheduler and landing paths" do
    set_feature("work_units_scheduler", true)
    set_feature("work_units_landing", true)
    set_feature("work_units_reconciler", false)

    expect(described_class.for("stale_runs")).to be_legacy
    expect(described_class.for("epic_wide_workflow")).to be_legacy

    set_feature("work_units_reconciler", true)

    expect(described_class.for("stale_runs")).to be_work_unit
    expect(described_class.for("epic_wide_workflow")).to be_work_unit
  end

  it "raises for unknown paths instead of silently choosing an owner" do
    expect { described_class.for("new_unregistered_path") }
      .to raise_error(KeyError, /unknown work unit ownership path/)
  end

  it "selects exactly one owner for every registered rollout path" do
    described_class::PATH_GATES.each do |path, gate|
      described_class::PATH_GATES.values.uniq.each { |slug| set_feature(slug, false) }

      disabled = described_class.for(path)
      expect(disabled).to be_legacy
      expect(disabled).not_to be_work_unit
      expect(disabled.gate).to eq(gate)

      (described_class::PATH_GATES.values.uniq - [ gate ]).each { |slug| set_feature(slug, true) }
      other_gates_enabled = described_class.for(path)
      expect(other_gates_enabled).to be_legacy
      expect(other_gates_enabled).not_to be_work_unit

      set_feature(gate, true)
      enabled = described_class.for(path)
      expect(enabled).to be_work_unit
      expect(enabled).not_to be_legacy
    end
  end
end
