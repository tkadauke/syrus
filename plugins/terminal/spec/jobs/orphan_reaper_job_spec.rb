require "rails_helper"

RSpec.describe Terminal::OrphanReaperJob, type: :job do
  include ActiveJob::TestHelper

  it "runs orphan cleanup on the plugin queue" do
    allow(Terminal::OrphanReaper).to receive(:run!)

    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue("plugin_terminal")
    described_class.perform_now

    expect(Terminal::OrphanReaper).to have_received(:run!)
  end
end
