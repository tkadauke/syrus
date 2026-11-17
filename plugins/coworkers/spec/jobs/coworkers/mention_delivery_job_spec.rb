require "rails_helper"

RSpec.describe Coworkers::MentionDeliveryJob do
  include ActiveJob::TestHelper

  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:source_chat) { ChatSession.create!(user: owner, repository: repository, title: "Source") }

  def coworker(name, handle)
    Coworkers::Coworker.create!(owner_user: owner, name:, handle:, workspace_repo: repository.remote_url)
  end

  before { PluginRecord.find_by!(name: "coworkers").update!(enabled: true) }

  it "queues only the first rostered mention and starts its hidden session turn" do
    first = coworker("Maya", "maya-delivery")
    second = coworker("Rin", "rin-delivery")
    [ first, second ].each { |agent| Coworkers::ChatAgent.create!(chat_session: source_chat, coworker: agent, added_by_user: owner) }
    text = "@maya-delivery and @rin-delivery please help"
    mentions = source_chat.resolve_mentions(text)

    expect(source_chat.should_trigger_agent?(mentions)).to be(false)
    message = source_chat.messages.create!(
      role: "user", content: { "text" => text }, mentions:, sender_user: owner, skip_turn_trigger: true
    )

    deliveries = enqueued_jobs.select { |job| job.fetch(:job) == described_class }
    expect(deliveries.one?).to be(true)
    expect(deliveries.sole.fetch(:args)).to eq([ message.id, first.id ])

    clear_enqueued_jobs
    described_class.perform_now(message.id, first.id)
    link = Coworkers::Chat.find_by!(coworker: first, source_chat_session: source_chat, role: "mention")
    expect(enqueued_jobs).to include(hash_including(job: ChatTurnJob, args: [ link.chat_session_id, link.chat_session.messages.last.id ]))
    expect(Coworkers::Chat.where(coworker: second, role: "mention")).to be_empty
  end

  it "applies the coworker hop cap to a relayed mention" do
    sender = coworker("Maya", "maya-hop")
    receiver = coworker("Rin", "rin-hop")
    Coworkers::ChatAgent.create!(chat_session: source_chat, coworker: receiver, added_by_user: owner)
    message = source_chat.messages.create!(
      role: "assistant",
      content: {
        "text" => "@rin-hop continue", "source" => "coworker_message",
        "coworker_message" => { "sender_id" => sender.id, "hop_count" => Coworkers::MessageDispatcher::MAX_HOPS }
      },
      skip_turn_trigger: true
    )

    expect { described_class.perform_now(message.id, receiver.id) }
      .not_to change { Coworkers::Chat.where(role: "mention").count }
    expect(source_chat.messages.last.extract_text_from_content).to include("hop limit")
  end
end
