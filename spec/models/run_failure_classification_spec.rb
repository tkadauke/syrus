require "rails_helper"

RSpec.describe RunFailureClassification, type: :model do
  let(:run) { Factories.run }

  def valid_attrs(overrides = {})
    {
      run: run,
      classification: "worker_died",
      classified_at: Time.current,
      retryable: true
    }.merge(overrides)
  end

  it "is valid with all required attributes" do
    expect(described_class.new(valid_attrs)).to be_valid
  end

  it "requires classification" do
    expect(described_class.new(valid_attrs(classification: nil))).not_to be_valid
  end

  it "requires classified_at" do
    expect(described_class.new(valid_attrs(classified_at: nil))).not_to be_valid
  end

  it "requires retryable to be a boolean" do
    expect(described_class.new(valid_attrs(retryable: nil))).not_to be_valid
    expect(described_class.new(valid_attrs(retryable: true))).to be_valid
    expect(described_class.new(valid_attrs(retryable: false))).to be_valid
  end

  it "enforces one classification per run" do
    described_class.create!(valid_attrs)

    duplicate = described_class.new(valid_attrs)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:run_id]).to be_present
  end

  it "accepts optional confidence between 0 and 1" do
    expect(described_class.new(valid_attrs(confidence: 0.85))).to be_valid
    expect(described_class.new(valid_attrs(confidence: 0.0))).to be_valid
    expect(described_class.new(valid_attrs(confidence: 1.0))).to be_valid
    expect(described_class.new(valid_attrs(confidence: nil))).to be_valid
  end

  it "rejects confidence outside 0-1" do
    expect(described_class.new(valid_attrs(confidence: -0.1))).not_to be_valid
    expect(described_class.new(valid_attrs(confidence: 1.1))).not_to be_valid
  end

  it "stores and retrieves classifier_inputs as JSON" do
    inputs = { "logs" => "something failed", "exit_code" => 1 }
    record = described_class.create!(valid_attrs(classifier_inputs: inputs))

    expect(record.reload.classifier_inputs).to eq(inputs)
  end

  it "belongs to a run" do
    record = described_class.create!(valid_attrs)

    expect(record.run).to eq(run)
  end
end
