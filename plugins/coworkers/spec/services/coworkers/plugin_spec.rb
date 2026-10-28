require "rails_helper"

RSpec.describe "Coworkers plugin" do
  let(:owner) { User.create!(email_address: "owner@example.com", password: "password123") }

  it "is experimental and disabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "coworkers" }

    expect(manifest).to be_experimental
    expect(manifest).not_to be_default_enabled
  end

  it "resolves an unlinked chat to the built-in Syrus coworker" do
    chat = ChatSession.create!(user: owner, title: "Existing chat")
    scope = Syrus::EffectScope.new(label: "spec")
    Coworkers::ChatExtension.install_into(scope)

    expect(chat.coworker).to be_a(Coworker::Syrus)
    expect(chat.coworker).to have_attributes(owner_user: owner, handle: "syrus", workspace_repo: nil)
  ensure
    scope&.dispose
  end

  it "resolves linked chats and contributes their coworker as a mentionable" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git")
    chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    scope = Syrus::EffectScope.new(label: "spec")
    Coworkers::ChatExtension.install_into(scope)

    expect(chat.coworker).to eq(coworker)
    expect(Coworkers::MentionableProvider.mentionables(chat: chat)).to contain_exactly(coworker)
  ensure
    scope&.dispose
  end

  it "removes the chat extension when disabled" do
    scope = Syrus::EffectScope.new(label: "spec")
    Coworkers::ChatExtension.install_into(scope)
    expect(ChatSession.new).to respond_to(:coworker)

    scope.dispose
    expect(ChatSession.new).not_to respond_to(:coworker)
  end

  it "cleans plugin rows up with their core owners" do
    scope = Syrus::EffectScope.new(label: "spec")
    Coworkers::DataCleanup.install_into(scope)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git")
    chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    chat.destroy!
    expect(Coworkers::Chat.where(coworker: coworker)).to be_empty

    owner.destroy!
    expect(Coworkers::Coworker.where(id: coworker.id)).to be_empty
  ensure
    scope&.dispose
  end
end
