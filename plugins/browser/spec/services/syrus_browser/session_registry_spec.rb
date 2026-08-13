require "rails_helper"

RSpec.describe SyrusBrowser::SessionRegistry do
  let(:fake_session) { instance_double(SyrusBrowser::Session, close: nil) }

  before do
    described_class.session_factory = ->(_run_id) { fake_session }
  end

  after do
    described_class.reset!
  end

  describe ".fetch" do
    it "spawns a session on first fetch for a run" do
      expect(described_class.fetch(1)).to eq(fake_session)
    end

    it "reuses the same session across calls for the same run" do
      spawn_count = 0
      described_class.session_factory = ->(_run_id) {
        spawn_count += 1
        fake_session
      }

      described_class.fetch(1)
      described_class.fetch(1)

      expect(spawn_count).to eq(1)
    end

    it "spawns a distinct session per run" do
      other_session = instance_double(SyrusBrowser::Session, close: nil)
      calls = { 1 => fake_session, 2 => other_session }
      described_class.session_factory = ->(run_id) { calls.fetch(run_id) }

      expect(described_class.fetch(1)).to eq(fake_session)
      expect(described_class.fetch(2)).to eq(other_session)
    end
  end

  describe ".kill" do
    it "closes and forgets the session for that run" do
      described_class.fetch(1)

      expect(fake_session).to have_received(:close).exactly(0).times
      described_class.kill(1)
      expect(fake_session).to have_received(:close)
    end

    it "spawns a fresh session on the next fetch after kill" do
      spawn_count = 0
      described_class.session_factory = ->(_run_id) {
        spawn_count += 1
        fake_session
      }

      described_class.fetch(1)
      described_class.kill(1)
      described_class.fetch(1)

      expect(spawn_count).to eq(2)
    end

    it "is a no-op for a run with no session" do
      expect { described_class.kill(999) }.not_to raise_error
    end
  end

  describe ".kill_all" do
    it "closes every tracked session and clears the registry" do
      session_a = instance_double(SyrusBrowser::Session, close: nil)
      session_b = instance_double(SyrusBrowser::Session, close: nil)
      calls = { 1 => session_a, 2 => session_b }
      described_class.session_factory = ->(run_id) { calls.fetch(run_id) }

      described_class.fetch(1)
      described_class.fetch(2)
      described_class.kill_all

      expect(session_a).to have_received(:close)
      expect(session_b).to have_received(:close)

      spawn_count = 0
      described_class.session_factory = ->(_run_id) {
        spawn_count += 1
        fake_session
      }
      described_class.fetch(1)
      expect(spawn_count).to eq(1)
    end
  end
end
