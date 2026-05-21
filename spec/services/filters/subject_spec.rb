require "rails_helper"

RSpec.describe Filters::Subject do
  describe ".subject_for" do
    it "returns the job subject" do
      subject = Filters.subject_for(:job)

      expect(subject).to be_a(described_class)
      expect(subject.name).to eq(:job)
      expect(subject.model).to eq(Job)
      expect(subject.chips).to eq(Filters::Registry::CHIPS)
    end

    it "accepts string subject names" do
      expect(Filters.subject_for("job").name).to eq(:job)
    end

    it "returns the admin user subject" do
      subject = Filters.subject_for(:admin_user)

      expect(subject).to be_a(described_class)
      expect(subject.name).to eq(:admin_user)
      expect(subject.model).to eq(User)
      expect(Filters::Registry.fields(subject: :admin_user)).to eq(%w[
        email
        admin
        has_github_token
        has_claude_token
        has_codex_token
        gh_rate
      ])
    end

    it "raises a clear error for unknown subjects" do
      expect {
        Filters.subject_for(:made_up)
      }.to raise_error(ArgumentError, "unknown subject: made_up")
    end
  end

  describe "#find_chip" do
    it "resolves chips through the subject chip map" do
      subject = Filters.subject_for(:job)

      expect(subject.find_chip("state")).to eq(Filters::Chips::Jobs::State)
    end

    it "raises UnknownFilterField for fields outside the subject chip map" do
      subject = Filters.subject_for(:job)

      expect {
        subject.find_chip("made_up_filter")
      }.to raise_error(Filters::UnknownFilterField)
    end
  end
end
