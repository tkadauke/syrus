require "rails_helper"

RSpec.describe Admission::SpendBudget do
  let(:user) { Factories.user }

  def spend!(amount, at: Time.current)
    job = Factories.job_with_run(user: user)
    job.runs.first.update!(user: user, cost_usd: amount, created_at: at)
  end

  it "does not limit anyone when no budget is set" do
    spend!(100)

    result = described_class.for(user: user, budget_usd: 0)

    expect(result).not_to be_over_budget
    expect(result).to be_unlimited
  end

  it "is under budget below the ceiling" do
    spend!(3)

    expect(described_class.for(user: user, budget_usd: 10)).not_to be_over_budget
  end

  it "is over budget at the ceiling" do
    spend!(10)

    result = described_class.for(user: user, budget_usd: 10)

    expect(result).to be_over_budget
    expect(result.spent_usd).to be_within(0.001).of(10)
  end

  # "Daily" means the calendar day to the person who set it.
  it "ignores spend from a previous day" do
    spend!(50, at: 2.days.ago)

    expect(described_class.for(user: user, budget_usd: 10)).not_to be_over_budget
  end

  it "reports when the budget resets, since that is when work resumes" do
    spend!(10)

    expect(described_class.for(user: user, budget_usd: 10).resets_at).to eq(Time.current.end_of_day)
  end

  it "counts only this user's spend" do
    other = Factories.user
    job = Factories.job_with_run(user: other)
    job.runs.first.update!(user: other, cost_usd: 100)

    expect(described_class.for(user: user, budget_usd: 10)).not_to be_over_budget
  end
end
