require "rails_helper"

RSpec.describe Coworkers::Chat do
  let(:owner) { Factories.user }
  let(:workspace_repository) { Factories.repository(user: owner, owner: "acme", name: "maya-workspace") }
  let(:product_repository) { Factories.repository(user: owner, owner: "acme", name: "product") }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya", workspace_repo: workspace_repository.remote_url
    )
  end
  let(:effect_scope) { Syrus::EffectScope.new(label: "coworker repository spec") }

  before { Coworkers::ChatExtension.install_into(effect_scope) }
  after { effect_scope.dispose }

  def coworker_chat(first_repository:, second_repository:)
    chat = ChatSession.create!(user: owner, repository: first_repository)
    described_class.create!(chat_session: chat, coworker: coworker, role: "main")
    chat.chat_attachments.create!(attachable: second_repository, attached_at: 1.hour.from_now)
    chat.reload
  end

  it "keeps the workspace primary when a product repository is attached later" do
    chat = coworker_chat(first_repository: workspace_repository, second_repository: product_repository)

    expect(chat.attached_repositories).to contain_exactly(workspace_repository, product_repository)
    expect(chat.repository).to eq(workspace_repository)
    expect(chat.repository_id).to eq(workspace_repository.id)
  end

  it "keeps the workspace primary when it was attached after a product repository" do
    chat = coworker_chat(first_repository: product_repository, second_repository: workspace_repository)

    expect(chat.repository).to eq(workspace_repository)
    expect(chat.repository_id).to eq(workspace_repository.id)
  end

  it "keeps the workspace primary after detaching a product repository" do
    chat = coworker_chat(first_repository: workspace_repository, second_repository: product_repository)

    chat.chat_attachments.find_by!(attachable: product_repository).destroy!

    expect(chat.reload.repository).to eq(workspace_repository)
    expect(chat.attached_repositories).to contain_exactly(workspace_repository)
  end
end
