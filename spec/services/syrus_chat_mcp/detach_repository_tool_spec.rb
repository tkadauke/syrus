require "rails_helper"

RSpec.describe Mcp::Tools::DetachRepositoryTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus", default_branch: "main") }
  let(:other_repository) { Factories.repository(user: user, owner: "tkadauke", name: "other", default_branch: "main") }
  let(:chat_session) { ChatSession.create!(user: user) }

  def payload(response)
    JSON.parse(response.content.first[:text])
  end

  it "detaches an attached repository and reports what remains" do
    chat_session.chat_attachments.create!(attachable: repository)

    response = described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })

    expect(response.instance_variable_get(:@error)).to be_falsey
    expect(payload(response)).to include(
      "repository" => { "id" => repository.id, "slug" => "tkadauke/syrus" },
      "detached" => true,
      "remaining_repositories" => []
    )
    expect(chat_session.reload.attached_repositories).to be_empty
  end

  it "is case-insensitive on the slug" do
    chat_session.chat_attachments.create!(attachable: repository)

    response = described_class.call(slug: "TKadauke/Syrus", server_context: { chat_session: chat_session })

    expect(response.instance_variable_get(:@error)).to be_falsey
    expect(chat_session.reload.attached_repositories).to be_empty
  end

  it "returns a validation error for a repository not attached to this chat" do
    response = described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })

    expect(response.instance_variable_get(:@error)).to eq(true)
    expect(response.content.first[:text]).to include("is not attached to this chat")
  end

  it "returns a validation error for a malformed slug" do
    response = described_class.call(slug: "not-a-slug", server_context: { chat_session: chat_session })

    expect(response.instance_variable_get(:@error)).to eq(true)
    expect(response.content.first[:text]).to include("owner/name")
  end

  it "detaches only the matching repository, leaving other attachments untouched" do
    chat_session.chat_attachments.create!(attachable: repository)
    chat_session.chat_attachments.create!(attachable: other_repository)
    job = Factories.job(repository: repository, user: user)
    chat_session.chat_attachments.create!(attachable: job)

    response = described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })

    expect(payload(response).fetch("remaining_repositories")).to eq(
      [ { "id" => other_repository.id, "slug" => other_repository.slug } ]
    )
    chat_session.reload
    expect(chat_session.attached_repositories).to contain_exactly(other_repository)
    expect(chat_session.attached_jobs).to contain_exactly(job)
  end

  # The effective repository is the most recently attached one
  # (ChatSession#repository), so `other_repository` -- attached second -- is
  # the one whose removal changes what is effective. These two examples had
  # the slugs the other way round and were asserting the opposite rule.
  it "notes that another repository is now effective when the effective repository is detached" do
    chat_session.chat_attachments.create!(attachable: repository)
    chat_session.chat_attachments.create!(attachable: other_repository)

    response = described_class.call(slug: "tkadauke/other", server_context: { chat_session: chat_session })

    expect(payload(response).fetch("note")).to include(repository.slug)
  end

  it "notes that no repository remains effective when the only attached repository is detached" do
    chat_session.chat_attachments.create!(attachable: repository)

    response = described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })

    expect(payload(response).fetch("note")).to match(/only attached repository/)
  end

  it "does not comment on effectiveness when detaching a non-effective repository" do
    chat_session.chat_attachments.create!(attachable: repository)
    chat_session.chat_attachments.create!(attachable: other_repository)

    response = described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })

    expect(payload(response)["note"]).to be_nil
  end
end
