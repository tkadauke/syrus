require "rails_helper"

RSpec.describe Coworkers::WorkspaceSaveRetryJob do
  it "ignores a superseded retry token instead of forking another retry chain" do
    link = instance_double(Coworkers::Chat, id: 7, chat_session: instance_double(ChatSession))
    state = instance_double(Coworkers::UnsavedWorkspace, begin_retry!: false)
    allow(Coworkers::Chat).to receive(:find_by).with(id: 7).and_return(link)
    allow(Coworkers::UnsavedWorkspace).to receive(:new).with(link.chat_session).and_return(state)
    allow(Coworkers::WorkspaceSaveRetry).to receive(:for)

    described_class.perform_now(7, "superseded")

    expect(Coworkers::WorkspaceSaveRetry).not_to have_received(:for)
  end
end
