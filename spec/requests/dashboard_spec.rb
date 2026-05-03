require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  let(:user)  { Factories.user }
  let(:other) { Factories.user }

  it "requires authentication" do
    get root_path
    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "lists the current user's recent jobs" do
      mine_repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.job(repository: mine_repo, issue_number: 7)

      other_repo = Factories.repository(user: other, owner: "globex", name: "things")
      Factories.job(repository: other_repo, issue_number: 99)

      get root_path
      expect(response.body).to include("acme/widgets")
      expect(response.body).to include("#7")
      expect(response.body).not_to include("globex/things")
      expect(response.body).not_to include("#99")
    end

    it "shows the empty state when no jobs exist" do
      get root_path
      expect(response.body).to include("No jobs yet")
    end

    describe "filters" do
      let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

      describe "state filter" do
        it "shows only open jobs when state=open" do
          open_job   = Factories.job(repository: repo, issue_number: 1)
          closed_job = Factories.job(repository: repo, issue_number: 2)
          closed_job.close!; closed_job.save!

          get root_path, params: { state: "open" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only closed jobs when state=closed" do
          open_job   = Factories.job(repository: repo, issue_number: 1)
          closed_job = Factories.job(repository: repo, issue_number: 2)
          closed_job.close!; closed_job.save!

          get root_path, params: { state: "closed" }
          expect(response.body).not_to include("#1")
          expect(response.body).to include("#2")
        end

        it "shows all jobs when state is absent" do
          open_job   = Factories.job(repository: repo, issue_number: 1)
          closed_job = Factories.job(repository: repo, issue_number: 2)
          closed_job.close!; closed_job.save!

          get root_path
          expect(response.body).to include("#1")
          expect(response.body).to include("#2")
        end
      end

      describe "repository filter" do
        it "shows only jobs for the selected repository" do
          repo_a = Factories.repository(user: user, owner: "acme", name: "alpha")
          repo_b = Factories.repository(user: user, owner: "acme", name: "beta")
          Factories.job(repository: repo_a, issue_number: 10)
          Factories.job(repository: repo_b, issue_number: 20)

          get root_path, params: { repository_id: repo_a.id }
          expect(response.body).to include("#10")
          expect(response.body).not_to include("#20")
        end
      end

      describe "PR filter" do
        it "shows only jobs with a PR when pr=has_pr" do
          with    = Factories.job(repository: repo, issue_number: 1)
          without = Factories.job(repository: repo, issue_number: 2)
          with.update!(pr_number: 99)

          get root_path, params: { pr: "has_pr" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only jobs without a PR when pr=no_pr" do
          with    = Factories.job(repository: repo, issue_number: 1)
          without = Factories.job(repository: repo, issue_number: 2)
          with.update!(pr_number: 99)

          get root_path, params: { pr: "no_pr" }
          expect(response.body).not_to include("#1")
          expect(response.body).to include("#2")
        end

        it "includes jobs with external_pr_number in has_pr results" do
          external = Factories.job(repository: repo, issue_number: 5,
                                   state: "closed", closure_reason: "preempted",
                                   external_pr_number: 7, finished_at: Time.current)
          get root_path, params: { pr: "has_pr" }
          expect(response.body).to include("#5")
        end
      end

      describe "age filter" do
        it "shows only jobs created within the last day when age=1d" do
          recent = Factories.job(repository: repo, issue_number: 1)
          old    = Factories.job(repository: repo, issue_number: 2)
          old.update_column(:created_at, 2.days.ago)

          get root_path, params: { age: "1d" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only jobs created within the last 7 days when age=7d" do
          recent = Factories.job(repository: repo, issue_number: 1)
          old    = Factories.job(repository: repo, issue_number: 2)
          old.update_column(:created_at, 8.days.ago)

          get root_path, params: { age: "7d" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only jobs created within the last 30 days when age=30d" do
          recent = Factories.job(repository: repo, issue_number: 1)
          old    = Factories.job(repository: repo, issue_number: 2)
          old.update_column(:created_at, 31.days.ago)

          get root_path, params: { age: "30d" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "ignores an unrecognised age value and shows all jobs" do
          Factories.job(repository: repo, issue_number: 1)
          get root_path, params: { age: "bogus" }
          expect(response.body).to include("#1")
        end
      end

      describe "combined filters" do
        it "applies state and repository filters together" do
          repo_a = Factories.repository(user: user, owner: "acme", name: "alpha")
          repo_b = Factories.repository(user: user, owner: "acme", name: "beta")

          open_a  = Factories.job(repository: repo_a, issue_number: 1)
          closed_a = Factories.job(repository: repo_a, issue_number: 2)
          closed_a.close!; closed_a.save!
          open_b  = Factories.job(repository: repo_b, issue_number: 3)

          get root_path, params: { state: "open", repository_id: repo_a.id }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
          expect(response.body).not_to include("#3")
        end
      end
    end
  end
end
