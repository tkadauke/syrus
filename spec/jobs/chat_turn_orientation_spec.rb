require "rails_helper"

# The seam, not any particular plugin: core asks whoever owns an incoming
# message how the turn should open, and a plugin that claims one replaces the
# user's text for that turn.
RSpec.describe "ChatTurnJob plugin turn orientation" do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }
  let(:message) { ChatMessage.create!(chat_session: chat, role: "user", content: { "text" => "hi" }) }

  def orientation(user_note: "hi")
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    job.instance_variable_set(:@user_message, message)
    job.send(:plugin_turn_orientation, user_note: user_note)
  end

  # Only this extension point is stubbed; everything else the job reaches for
  # keeps its real providers.
  def stub_orientation_providers(providers = [])
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_turn_orientation).and_return(providers)
  end

  def provider(&block)
    Module.new do
      include Syrus::Plugin::ChatTurnOrientation
      define_singleton_method(:chat_turn_orientation) { |chat_session:, message:, user_note:| block.call(user_note) }
    end
  end

  it "returns nothing when no plugin claims the message" do
    stub_orientation_providers([])

    expect(orientation).to be_nil
  end

  it "uses the first provider that claims the message" do
    stub_orientation_providers([ provider { nil }, provider { |note| "oriented: #{note}" }, provider { "never reached" } ])

    expect(orientation).to eq("oriented: hi")
  end

  # A provider that cannot orient the turn must not cost the user their turn.
  it "falls through to a normal turn when a provider raises" do
    stub_orientation_providers([ provider { raise "boom" }, provider { "recovered" } ])

    expect(orientation).to eq("recovered")
  end

  it "treats a blank answer as no claim" do
    stub_orientation_providers([ provider { "  " }, provider { "claimed" } ])

    expect(orientation).to eq("claimed")
  end

  it "includes cross-chat provenance in the built prompt for a bridged turn" do
    origin_chat = ChatSession.create!(user: user, title: "Release planning")
    thread = ChatBridgeThread.create!(origin_chat_session: origin_chat, target_chat_session: chat, opened_by_user: user)
    bridged_message = ChatMessage.create!(
      chat_session: chat,
      role: "user",
      content: {
        "text" => "Can you check the deploy blocker?",
        "requested_by" => "cross_chat",
        "origin_chat_session_id" => origin_chat.id,
        "thread_id" => thread.id
      }
    )
    job = build_job_for_prompt(bridged_message)

    prompt = job.send(:prompt_for, nil, user_text: "Can you check the deploy blocker?")

    expect(prompt).to include("Cross-chat bridge message")
    expect(prompt).to include("Origin chat: ##{origin_chat.id} (Release planning)")
    expect(prompt).to include("Bridge thread: ##{thread.id}")
    expect(prompt).to include("not typed directly by the human operator")
    expect(prompt).to include("Message:\nCan you check the deploy blocker?")
  end

  it "does not include cross-chat provenance in the built prompt for a normal user turn" do
    job = build_job_for_prompt(message)

    prompt = job.send(:prompt_for, nil, user_text: "hi")

    expect(prompt).not_to include("Cross-chat bridge message")
    expect(prompt).not_to include("not typed directly by the human operator")
  end

  def build_job_for_prompt(prompt_message)
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    job.instance_variable_set(:@user_message, prompt_message)
    job
  end
end
