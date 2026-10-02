require "rails_helper"

RSpec.describe "Slug redirects", type: :request do
  let!(:bootstrap_admin) { Factories.user(global_role: "admin") }
  let(:user) { Factories.user(global_role: "user") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  it "redirects accessible Job refs to the app path" do
    job = Factories.job_record(user: user, repository: repository)

    get "/s/JOB-#{job.id}"

    expect(response).to redirect_to("/jobs/JOB-#{job.id}")
  end

  it "redirects accessible Epic refs to the app path" do
    epic = Factories.epic(user: user, repository: repository)

    get "/s/EPIC-#{epic.number}"

    expect(response).to redirect_to("/epics/EPIC-#{epic.number}")
  end

  it "redirects accessible Chat refs to the app path" do
    chat = ChatSession.create!(user: user)

    get "/s/CHAT-#{chat.id}"

    expect(response).to redirect_to("/chats/#{chat.id}")
  end

  it "does not reveal inaccessible refs" do
    other_user = Factories.user(global_role: "user")
    private_repo = Factories.repository(user: other_user, owner: "private", name: "repo")
    private_job = Factories.job_record(user: other_user, repository: private_repo)

    get "/s/JOB-#{private_job.id}"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_blank
  end

  it "does not reveal unknown or malformed refs" do
    get "/s/NOTE-1"
    expect(response).to have_http_status(:not_found)

    get "/s/JOB-nope"
    expect(response).to have_http_status(:not_found)
  end
end
