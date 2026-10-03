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

  it "redirects accessible root-level Job refs to the canonical app path" do
    job = Factories.job_record(user: user, repository: repository)

    get "/JOB-#{job.id}"

    expect(response).to redirect_to("/jobs/JOB-#{job.id}")
  end

  it "redirects accessible Epic refs to the app path" do
    epic = Factories.epic(user: user, repository: repository)

    get "/s/EPIC-#{epic.number}"

    expect(response).to redirect_to("/epics/EPIC-#{epic.number}")
  end

  it "redirects accessible root-level Epic refs to the canonical app path" do
    epic = Factories.epic(user: user, repository: repository)

    get "/EPIC-#{epic.number}"

    expect(response).to redirect_to("/epics/EPIC-#{epic.number}")
  end

  it "redirects accessible Chat refs to the app path" do
    chat = ChatSession.create!(user: user)

    get "/s/CHAT-#{chat.id}"

    expect(response).to redirect_to("/chats/#{chat.id}")
  end

  it "redirects accessible root-level Chat refs to the canonical app path" do
    chat = ChatSession.create!(user: user)

    get "/CHAT-#{chat.id}"

    expect(response).to redirect_to("/chats/#{chat.id}")
  end

  it "redirects accessible root-level Design Doc refs through the plugin slug provider" do
    design_doc = DesignDocs::DesignDoc.create!(
      owner_user: user,
      title: "Bridge plan",
      markdown: "# Bridge",
      visibility: "private"
    )
    version = design_doc.versions.create!(
      markdown: design_doc.markdown,
      version_number: 1,
      actor_kind: "user",
      actor_user: user
    )
    design_doc.update!(current_version: version)

    get "/DOC-#{design_doc.id}"

    expect(response).to redirect_to("/design_docs/#{design_doc.id}")
  end

  it "does not reveal inaccessible refs" do
    other_user = Factories.user(global_role: "user")
    private_repo = Factories.repository(user: other_user, owner: "private", name: "repo")
    private_job = Factories.job_record(user: other_user, repository: private_repo)

    get "/s/JOB-#{private_job.id}"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_blank
  end

  it "does not reveal inaccessible root-level refs" do
    other_user = Factories.user(global_role: "user")
    private_repo = Factories.repository(user: other_user, owner: "private", name: "repo")
    private_job = Factories.job_record(user: other_user, repository: private_repo)

    get "/JOB-#{private_job.id}"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_blank
  end

  it "does not reveal unknown or malformed refs" do
    get "/s/NOTE-1"
    expect(response).to have_http_status(:not_found)

    get "/s/JOB-nope"
    expect(response).to have_http_status(:not_found)
  end

  it "does not reveal unknown root-level slug-shaped refs" do
    get "/NOTE-1"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_blank
  end
end
