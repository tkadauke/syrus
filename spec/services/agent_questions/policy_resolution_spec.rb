require "rails_helper"

RSpec.describe AgentQuestions::PolicyResolution do
  let(:user) { Factories.user(question_eagerness: "independent", question_answer_timeout_seconds: 2.hours.to_i) }
  let(:repository) { Factories.repository(user: user, question_eagerness: "collaborative", question_answer_timeout_seconds: 3.hours.to_i) }
  let(:job) { Factories.job(user: user, repository: repository) }

  it "resolves job, repository, user, then defaults and explains each source" do
    expect(described_class.for(job)).to have_attributes(eagerness: "collaborative", eagerness_source: "repository", timeout: 3.hours, timeout_source: "repository")

    job.update!(question_eagerness: "autonomous", question_answer_timeout_seconds: 4.hours.to_i)
    expect(described_class.for(job)).to have_attributes(eagerness: "autonomous", eagerness_source: "job", timeout: 4.hours, timeout_source: "job")

    job.update!(question_eagerness: nil, question_answer_timeout_seconds: nil)
    repository.update!(question_eagerness: nil, question_answer_timeout_seconds: nil)
    job.reload
    expect(described_class.for(job)).to have_attributes(eagerness: "independent", eagerness_source: "user", timeout: 2.hours, timeout_source: "user")

    user.update!(question_eagerness: nil, question_answer_timeout_seconds: nil)
    job.reload
    expect(described_class.for(job)).to have_attributes(eagerness: "balanced", eagerness_source: "default", timeout: nil, timeout_source: "default")
  end

  it "rejects timeout values outside one hour through four weeks" do
    expect(job.tap { |record| record.question_answer_timeout_seconds = 59.minutes.to_i }).not_to be_valid
    expect(job.tap { |record| record.question_answer_timeout_seconds = 4.weeks.to_i + 1 }).not_to be_valid
  end
end
