require "rails_helper"

RSpec.describe "Repositories", type: :request do
  let(:user)  { Factories.user }
  let(:other) { Factories.user }

  it "requires authentication on index" do
    get repositories_path
    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "lists only the current user's repositories" do
      mine = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.repository(user: other, owner: "globex", name: "things")

      get repositories_path
      expect(response.body).to include("acme/widgets")
      expect(response.body).not_to include("globex/things")
    end

    it "creates with valid params" do
      expect {
        post repositories_path, params: { repository: {
          owner: "acme", name: "widgets", default_branch: "main",
          trigger_label: "syrus", polling_enabled: "1"
        } }
      }.to change(user.repositories, :count).by(1)
      expect(response).to redirect_to(repositories_path)
    end

    it "re-renders new on validation failure" do
      post repositories_path, params: { repository: { owner: "bad owner", name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("can")  # error messages present
    end

    it "scopes edit/update/destroy to the current user's repos" do
      foreign = Factories.repository(user: other, owner: "globex", name: "things")

      get edit_repository_path(foreign)
      expect(response).to have_http_status(:not_found).or redirect_to(repositories_path)
    end

    it "destroys" do
      mine = Factories.repository(user: user)
      expect {
        delete repository_path(mine)
      }.to change(user.repositories, :count).by(-1)
    end

    it "manual poll enqueues PollRepositoryJob with force: true" do
      mine = Factories.repository(user: user, polling_enabled: false)
      expect {
        post poll_repository_path(mine)
      }.to have_enqueued_job(PollRepositoryJob).with(mine.id, force: true)
      expect(response).to redirect_to(repository_path(mine))
      expect(flash[:notice]).to match(/Polling/)
    end

    describe "archive / unarchive" do
      it "archive stamps archived_at + flips polling off" do
        mine = Factories.repository(user: user, polling_enabled: true)
        post archive_repository_path(mine)
        expect(response).to redirect_to(repositories_path)
        expect(mine.reload).to be_archived
        expect(mine.polling_enabled).to be false
      end

      it "unarchive clears archived_at" do
        mine = Factories.repository(user: user)
        mine.archive!
        post unarchive_repository_path(mine)
        expect(response).to redirect_to(repositories_path)
        expect(mine.reload).not_to be_archived
      end

      it "archive/unarchive on another user's repo is not found" do
        foreign = Factories.repository(user: other)
        post archive_repository_path(foreign)
        expect(response).to have_http_status(:not_found).or redirect_to(repositories_path)
      end

      it "manual poll on an archived repo is rejected (does not enqueue)" do
        mine = Factories.repository(user: user)
        mine.archive!
        expect {
          post poll_repository_path(mine)
        }.not_to have_enqueued_job(PollRepositoryJob)
        expect(response).to redirect_to(repositories_path)
        expect(flash[:alert]).to match(/archived/)
      end

      it "index splits active and archived repositories" do
        active   = Factories.repository(user: user, owner: "active",   name: "one")
        archived = Factories.repository(user: user, owner: "archived", name: "two")
        archived.archive!

        get repositories_path
        expect(response.body).to include("active/one")
        expect(response.body).to include("archived/two")
        expect(response.body).to match(/Archived\s*\(\s*1\s*\)/)
      end
    end

    describe "GET /repositories/:id" do
      it "requires authentication" do
        # tested via the outer unauthenticated context below
      end

      it "renders the show page" do
        mine = Factories.repository(user: user, owner: "acme", name: "widgets")
        get repository_path(mine)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("acme/widgets")
      end

      it "shows only jobs belonging to this repository" do
        mine  = Factories.repository(user: user, owner: "acme", name: "widgets")
        other = Factories.repository(user: user, owner: "acme", name: "other")
        job_mine  = Factories.job(repository: mine)
        job_other = Factories.job(repository: other)

        get repository_path(mine)
        expect(response.body).to include(job_path(job_mine))
        expect(response.body).not_to include(job_path(job_other))
      end

      it "does not show another user's repository" do
        foreign = Factories.repository(user: other, owner: "globex", name: "things")
        get repository_path(foreign)
        expect(response).to have_http_status(:not_found)
      end

      it "links the slug to GitHub" do
        mine = Factories.repository(user: user, owner: "acme", name: "widgets")
        get repository_path(mine)
        expect(response.body).to include("https://github.com/acme/widgets")
      end
    end
  end

  it "requires authentication on show" do
    repo = Factories.repository(user: user)
    get repository_path(repo)
    expect(response).to redirect_to(new_session_path)
  end
end
