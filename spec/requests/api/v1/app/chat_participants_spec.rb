require "rails_helper"

RSpec.describe "App API chat participants", type: :request do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:third_user) { Factories.user }

  def parse_body = JSON.parse(response.body)
  def participants_path(chat_session) = "/api/v1/app/chats/#{chat_session.id}/participants"
  def participant_path(chat_session, target_user) = "/api/v1/app/chats/#{chat_session.id}/participants/#{target_user.id}"

  def group_chat(owner:, members: [])
    chat = ChatSession.create!(user: owner, conversation_kind: "group")
    members.each { |member| chat.chat_participants.create!(user: member, role: "member") }
    chat
  end

  describe "POST /api/v1/app/chats/:chat_id/participants" do
    it "adds a member to a group chat and broadcasts the updated participant set" do
      sign_in_as(user)
      chat = group_chat(owner: user, members: [ other_user ])

      expect(AppEvents).to receive(:broadcast).with(hash_including(user: user, resource: "chat", changed: [ "participants" ]))
      expect(AppEvents).to receive(:broadcast).with(hash_including(user: other_user, resource: "chat", changed: [ "participants" ]))
      expect(AppEvents).to receive(:broadcast).with(hash_including(user: third_user, resource: "chat", changed: [ "participants" ]))

      expect {
        post participants_path(chat), params: { user_id: third_user.id }
      }.to change(chat.chat_participants, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(chat.chat_participants.find_by(user: third_user).role).to eq("member")
      expect(parse_body["participants"].pluck("id")).to contain_exactly(user.id, other_user.id, third_user.id)
    end

    it "lets any current participant add a new participant, not just the owner" do
      sign_in_as(other_user)
      chat = group_chat(owner: user, members: [ other_user ])

      post participants_path(chat), params: { user_id: third_user.id }

      expect(response).to have_http_status(:created)
      expect(chat.chat_participants.reload.pluck(:user_id)).to include(third_user.id)
    end

    it "404s for a direct chat" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user)

      expect {
        post participants_path(chat), params: { user_id: other_user.id }
      }.not_to change(chat.chat_participants, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "404s when the caller is not a current participant" do
      sign_in_as(third_user)
      chat = group_chat(owner: user, members: [ other_user ])

      post participants_path(chat), params: { user_id: third_user.id }

      expect(response).to have_http_status(:not_found)
    end

    it "422s for an unknown user id" do
      sign_in_as(user)
      chat = group_chat(owner: user, members: [ other_user ])
      bogus_id = third_user.id + 100_000

      post participants_path(chat), params: { user_id: bogus_id }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "422s when the target is already a participant" do
      sign_in_as(user)
      chat = group_chat(owner: user, members: [ other_user ])

      post participants_path(chat), params: { user_id: other_user.id }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /api/v1/app/chats/:chat_id/participants/:user_id" do
    it "removes another participant and broadcasts to the removed user too" do
      sign_in_as(user)
      chat = group_chat(owner: user, members: [ other_user ])

      expect(AppEvents).to receive(:broadcast).with(hash_including(user: user, resource: "chat", changed: [ "participants" ]))
      expect(AppEvents).to receive(:broadcast).with(hash_including(user: other_user, resource: "chat", changed: [ "participants" ]))

      expect {
        delete participant_path(chat, other_user)
      }.to change(chat.chat_participants, :count).by(-1)

      expect(response).to have_http_status(:ok)
      expect(chat.chat_participants.reload.pluck(:user_id)).to contain_exactly(user.id)
      expect(parse_body["participants"].pluck("id")).to contain_exactly(user.id)
    end

    it "lets a participant remove themselves (leave)" do
      sign_in_as(other_user)
      chat = group_chat(owner: user, members: [ other_user ])

      delete participant_path(chat, other_user)

      expect(response).to have_http_status(:ok)
      expect(chat.chat_participants.reload.pluck(:user_id)).to contain_exactly(user.id)
    end

    it "404s for a direct chat" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user)

      delete participant_path(chat, user)

      expect(response).to have_http_status(:not_found)
    end

    it "404s when the caller is not a current participant" do
      sign_in_as(third_user)
      chat = group_chat(owner: user, members: [ other_user ])

      delete participant_path(chat, other_user)

      expect(response).to have_http_status(:not_found)
    end

    it "422s when the target is not a participant" do
      sign_in_as(user)
      chat = group_chat(owner: user, members: [ other_user ])

      delete participant_path(chat, third_user)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "422s when removal would leave the group with zero human participants" do
      sign_in_as(user)
      chat = group_chat(owner: user, members: [ other_user ])
      chat.chat_participants.find_by(user: other_user).destroy!

      expect {
        delete participant_path(chat, user)
      }.not_to change(chat.chat_participants, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
