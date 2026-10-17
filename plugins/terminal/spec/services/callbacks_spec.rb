require "rails_helper"

RSpec.describe Terminal::Callbacks do
  include ActiveJob::TestHelper

  it "enqueues orphan cleanup on each plugin tick" do
    expect { described_class.on_tick }.to have_enqueued_job(Terminal::OrphanReaperJob).on_queue("cleanup")
  end
end
