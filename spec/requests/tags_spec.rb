require "rails_helper"

RSpec.describe "Tags", type: :request do
  let(:user) { Factories.user }
  let(:other) { Factories.user }

  before { sign_in_as(user) }

  it "lists only the current user's tags" do
    Factories.tag(user: user, name: "mine", color: "blue")
    Factories.tag(user: other, name: "theirs", color: "red")

    get tags_path

    expect(response.body).to include("mine")
    expect(response.body).not_to include("theirs")
  end

  it "creates a tag" do
    expect {
      post tags_path, params: { tag: { name: "epic:attachments", color: "indigo" } }
    }.to change { user.tags.count }.by(1)

    expect(user.tags.last.name).to eq("epic:attachments")
    expect(response).to redirect_to(tags_path)
  end

  it "renames and recolors a tag" do
    tag = Factories.tag(user: user, name: "old", color: "gray")

    patch tag_path(tag), params: { tag: { name: "new", color: "green" } }

    expect(tag.reload.name).to eq("new")
    expect(tag.color).to eq("green")
  end

  it "deletes the tag and its job assignments" do
    repo = Factories.repository(user: user)
    job = Factories.job(repository: repo, issue_number: 7)
    tag = Factories.tag(user: user, name: "doomed", color: "red")
    job.tags << tag

    expect {
      delete tag_path(tag)
    }.to change { JobTag.count }.by(-1)

    expect(Tag.exists?(tag.id)).to be(false)
  end

  it "does not allow managing another user's tags" do
    tag = Factories.tag(user: other, name: "theirs", color: "red")

    patch tag_path(tag), params: { tag: { name: "stolen", color: "blue" } }

    expect(response).to have_http_status(:not_found)
    expect(tag.reload.name).to eq("theirs")
  end
end
