require "rails_helper"

RSpec.describe Problem::Kind do
  describe "the vocabulary is closed" do
    # The registry is only useful if it is exhaustive: an unregistered
    # classification would go back to being a private name nothing checks.
    # Scanned statically rather than asserted at runtime, because the emitters
    # run on the failure path where a new raise would turn a handled failure
    # into a crash.
    it "registers every classification RunFailureClassifier can emit" do
      source = Rails.root.join("app/services/run_failure_classifier.rb").read
      emitted = source.scan(/result\(\s*"([a-z_]+)"/).flatten
      emitted << ProviderUsageLimit::CLASSIFICATION

      expect(emitted.uniq.sort - described_class.values).to eq([])
    end

    it "registers no code the classifier cannot emit" do
      source = Rails.root.join("app/services/run_failure_classifier.rb").read
      emitted = source.scan(/result\(\s*"([a-z_]+)"/).flatten
      emitted << ProviderUsageLimit::CLASSIFICATION

      expect(described_class.values - emitted.uniq).to eq([])
    end

    it "registers every failure code a Step stamps for a Try branch" do
      codes = Rails.root.glob("app/services/steps/**/*.rb").flat_map do |path|
        path.read.scan(/FAILURE_CODE = "([a-z_]+)"/).flatten
      end

      expect(codes).not_to be_empty
      codes.each do |code|
        expect(described_class.resolve(code)).to be_present, "#{code.inspect} resolves to no problem kind"
      end
    end
  end

  describe ".resolve" do
    # The plan's worked example: one event that three planes each had their own
    # name for. This is the relationship that used to be convention.
    it "maps all three planes' names for a diverged branch onto one code" do
      %w[branch_diverged remote_branch_advanced_rebase_conflict branch_diverged_pr_open].each do |name|
        expect(described_class.resolve(name).code).to eq("branch_diverged")
      end
    end

    it "maps the merge-train step failure code onto the rebuild problem" do
      expect(described_class.resolve("merge_train_base_moved").code).to eq("merge_train_rebuild_required")
    end

    it "returns nil for a name no plane declares" do
      expect(described_class.resolve("not_a_real_failure")).to be_nil
    end
  end

  describe "entries" do
    it "declares a known scope and remediation for every code" do
      described_class.entries.each do |entry|
        expect(described_class::SCOPES).to include(entry.scope), "#{entry.code} has scope #{entry.scope.inspect}"
        expect(described_class::REMEDIATIONS).to include(entry.default_remediation),
          "#{entry.code} has remediation #{entry.default_remediation.inspect}"
      end
    end

    it "gives each alias exactly one owner" do
      owners = described_class.entries.flat_map { |entry| entry.aliases.map { |name| [ name, entry.code ] } }
      duplicated = owners.group_by(&:first).select { |_, pairs| pairs.size > 1 }

      expect(duplicated).to eq({})
    end

    it "rejects an unknown scope" do
      expect {
        described_class::Entry.new(code: "x", scope: :galaxy, retryable: false, default_remediation: :fail)
      }.to raise_error(ArgumentError, /unknown problem scope/)
    end

    it "rejects a remediation outside the closed action set" do
      expect {
        described_class::Entry.new(code: "x", scope: :run, retryable: false, default_remediation: :improvise)
      }.to raise_error(ArgumentError, /unknown remediation/)
    end
  end
end
