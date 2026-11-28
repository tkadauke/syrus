require "rails_helper"

RSpec.describe Invariants do
  it "registers every invariant under a unique key with a translated title and message" do
    expect(described_class.keys).to eq(%w[landing_progress slot_holders retry_storms failed_blockers zombie_workflows])

    %i[en de la].each do |locale|
      I18n.with_locale(locale) do
        described_class.keys.each do |key|
          expect(I18n.exists?("services.invariants.#{key}.title", locale)).to be(true), "#{locale} #{key} title"
          expect(I18n.exists?("services.invariants.#{key}.violation", locale)).to be(true), "#{locale} #{key} violation"
        end
      end
    end
  end

  it "evaluates every invariant into a report" do
    report = described_class.evaluate(now: Time.current)

    expect(report).to be_ok
    expect(report.results.map(&:key)).to eq(described_class.keys)
    expect(report.as_json[:invariants].first).to include(key: "landing_progress", violation_count: 0, error: nil, options: { threshold: 2.hours.to_i })
  end

  it "evaluates only the named invariants, with option overrides" do
    report = described_class.evaluate(now: Time.current, only: %w[retry_storms], options: { "retry_storms" => { max_failures: 2 } })

    expect(report.results.map(&:key)).to eq(%w[retry_storms])
    expect(report.results.first.options).to include(max_failures: 2, window: 1.hour)
  end

  it "rejects unknown invariant keys and options" do
    expect { described_class.evaluate(only: %w[nope]) }.to raise_error(Invariants::UnknownInvariant)
    expect { Invariants::RetryStorms.call(bogus: 1) }.to raise_error(ArgumentError, /bogus/)
  end

  it "records an invariant that raised without hiding the others" do
    allow(Invariants::RetryStorms).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "boom")

    report = described_class.evaluate(now: Time.current)

    expect(report).not_to be_ok
    expect(report.errors.map(&:key)).to eq(%w[retry_storms])
    expect(report.results.reject(&:error).size).to eq(described_class.keys.size - 1)
  end

  it "does not write while evaluating" do
    job = Factories.job_with_run(state: "approved", workflow_attrs: { state: "succeeded" }, run_attrs: { state: "succeeded" })
    job.update_columns(approved_at: Time.current)

    expect { described_class.evaluate(now: Time.current + 3.hours) }.not_to change { [ InvariantViolation.count, Job.maximum(:updated_at), Workflow.maximum(:updated_at) ] }
  end

  describe Invariants::Violation do
    it "bounds long fingerprints while keeping them distinct" do
      build = ->(suffix) do
        described_class.new(invariant: "slot_holders", severity: :critical, subject_type: "WorkUnit", subject_id: 1,
                            discriminator: "landing:#{'x' * 300}#{suffix}", message_params: {}, details: {})
      end

      expect(build.call("a").fingerprint.length).to be <= Invariants::FINGERPRINT_LIMIT
      expect(build.call("a").fingerprint).not_to eq(build.call("b").fingerprint)
    end

    it "rejects unknown severities" do
      expect {
        described_class.new(invariant: "x", severity: :meh, subject_type: "Job", subject_id: 1, message_params: {}, details: {})
      }.to raise_error(ArgumentError)
    end
  end
end
