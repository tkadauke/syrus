require "rails_helper"

# Replaces what `dependent: :destroy` on injected associations used to do.
RSpec.describe TestInsights::DataCleanup do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def build_test_run(run)
    TestInsights::TestRun.create!(
      run: run, repository: repository, grader_name: "rspec",
      total_count: 1, passed_count: 1, failed_count: 0
    )
  end

  it "removes a run's test results when the run is destroyed" do
    job = Factories.job(user: user, repository: repository)
    run = job.initial_run
    build_test_run(run)

    expect { run.destroy! }.to change(TestInsights::TestRun, :count).by(-1)
  end

  it "removes a repository's test identities when the repository is destroyed" do
    TestInsights::TestIdentity.create!(repository: repository, suite_name: "AuthSpec", name: "signs in", fingerprint: "auth-signs-in")

    expect { repository.destroy! }.to change(TestInsights::TestIdentity, :count).by(-1)
  end

  # The property that made this a cleanup registration rather than a
  # :domain_subscriber: disabling the plugin hides the feature, it does not
  # delete the rows, so the rows must still go when their parent does.
  it "still cleans up while the plugin is disabled" do
    PluginRecord.find_or_create_by!(name: "test_insights").update!(enabled: false, disableable: true)
    TestInsights::TestIdentity.create!(repository: repository, suite_name: "AuthSpec", name: "signs in", fingerprint: "auth-signs-in")

    expect { repository.destroy! }.to change(TestInsights::TestIdentity, :count).by(-1)
  end

  it "no longer declares associations on core models" do
    expect(Repository.reflect_on_association(:test_identities)).to be_nil
    expect(Run.reflect_on_association(:test_runs)).to be_nil
  end
end
