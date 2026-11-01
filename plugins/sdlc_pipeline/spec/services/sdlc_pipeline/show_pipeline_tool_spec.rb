require "rails_helper"

RSpec.describe SdlcPipeline::ShowPipelineTool do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user, title: "Delivery") }
  let(:repository) { Factories.repository(user: user) }
  let(:context) { { chat_session: chat } }

  it "authorizes the repository, validates the standard AST, and broadcasts a replay-safe presentation" do
    allow(AppEvents).to receive(:broadcast_chat_resource)
    filter = { "and" => [ { "field" => "associated_chat_id", "op" => "is", "value" => chat.id } ] }

    response = described_class.call(repository_id: repository.id, filter: filter, at: "2026-10-31T10:00:00Z", server_context: context)
    body = JSON.parse(response.content.first[:text])

    expect(body.dig("repository", "slug")).to eq(repository.slug)
    expect(body.fetch("path")).to include("/repositories/#{repository.id}/plugin/sdlc-pipeline?", "at=2026-10-31T10%3A00%3A00Z")
    expect(AppEvents).to have_received(:broadcast_chat_resource).with(hash_including(
      chat_session_id: chat.id,
      payload: hash_including(action: "open_tool_presentation", presentation: "sdlc_pipeline", title_i18n_key: "sdlc_pipeline:title", path: body.fetch("path"))
    ))
  end

  it "rejects inaccessible repositories, unknown filter fields, and malformed history values" do
    inaccessible = Factories.repository(user: Factories.user)
    inaccessible_response = described_class.call(repository_id: inaccessible.id, filter: { "and" => [] }, server_context: context)
    expect(inaccessible_response.error?).to be(true)

    response = described_class.call(repository_id: repository.id, filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "running" } ] }, server_context: context)
    expect(response.error?).to be(true)

    %i[at range_start range_end].each do |field|
      response = described_class.call(repository_id: repository.id, filter: { "and" => [] }, server_context: context, **{ field => "tomorrow-ish" })
      expect(response.error?).to be(true)
    end
  end
end
