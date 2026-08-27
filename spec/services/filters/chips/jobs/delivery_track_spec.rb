require "rails_helper"

RSpec.describe Filters::Chips::Jobs::DeliveryTrack do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def run_filter(op:, value:)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "delivery_track", "op" => op, "value" => value),
      scope: Job.where(repository: repo),
      user: user,
      subject: :job
    )
  end

  let!(:hotfix_job) { Factories.job_record(repository: repo, delivery_track: "hotfix") }
  let!(:release_job) { Factories.job_record(repository: repo, delivery_track: "release") }
  let!(:default_track_job) { Factories.job_record(repository: repo, delivery_track: nil) }

  it "matches jobs on the named track" do
    expect(run_filter(op: "is", value: "hotfix")).to contain_exactly(hotfix_job)
  end

  # SQL's three-valued NULL logic means a NULL delivery_track (the implicit
  # "default" track) matches neither `= 'hotfix'` nor `!= 'hotfix'` — the same
  # behavior every other EnumColumn-based chip already has.
  it "excludes jobs on other tracks with is_not, and also excludes untracked jobs" do
    expect(run_filter(op: "is_not", value: "hotfix")).to contain_exactly(release_job)
  end

  it "supports is_unset for jobs with no explicit track" do
    expect(run_filter(op: "is_unset", value: nil)).to contain_exactly(default_track_job)
  end
end
