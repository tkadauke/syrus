require "rails_helper"

RSpec.describe WorkEngine::Simulation::SolidQueueBootstrap do
  describe ".ensure!" do
    it "does not reset model metadata when the queue schema already exists" do
      allow(described_class).to receive(:all_tables_exist?).and_return(true)

      expect(described_class).not_to receive(:load_queue_schema!)
      expect(described_class).not_to receive(:reset_columns!)

      described_class.ensure!
    end

    it "resets model metadata after loading a missing queue schema" do
      allow(described_class).to receive(:all_tables_exist?).and_return(false)
      allow(described_class).to receive(:load_queue_schema!)
      allow(described_class).to receive(:reset_columns!)

      described_class.ensure!

      expect(described_class).to have_received(:load_queue_schema!).once
      expect(described_class).to have_received(:reset_columns!).once
    end
  end
end
