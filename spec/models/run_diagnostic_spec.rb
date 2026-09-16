require "rails_helper"

RSpec.describe RunDiagnostic do
  let(:run) { Factories.run }

  it "round-trips JSON-serialized hash columns" do
    diag = described_class.create!(
      run: run,
      error_class: "RuntimeError",
      error_message: "boom",
      git_snapshot:         { "head" => "abc123", "status" => " M file.rb" },
      environment_snapshot: { "RAILS_ENV" => "production" },
      repo_snapshot:        { "job_id" => 42 }
    )
    reloaded = described_class.find(diag.id)
    expect(reloaded.git_snapshot).to eq("head" => "abc123", "status" => " M file.rb")
    expect(reloaded.environment_snapshot).to eq("RAILS_ENV" => "production")
    expect(reloaded.repo_snapshot).to eq("job_id" => 42)
  end

  it "requires error_class" do
    diag = described_class.new(run: run, error_class: nil)
    expect(diag).not_to be_valid
  end

  describe ".prunable" do
    it "matches rows older than the configured retention window" do
      old = described_class.create!(run: Factories.run, error_class: "X")
      old.update_columns(created_at: (described_class.retention_window + 1.day).ago)
      fresh = described_class.create!(run: Factories.run, error_class: "X")
      expect(described_class.prunable).to include(old)
      expect(described_class.prunable).not_to include(fresh)
    end

    it "returns none when retention is set to 0 (infinite)" do
      AppSetting.current.update!(run_diagnostic_retention_days: 0)
      old = described_class.create!(run: Factories.run, error_class: "X")
      old.update_columns(created_at: 10.years.ago)

      expect(described_class.prunable).to be_empty
    end
  end
end
