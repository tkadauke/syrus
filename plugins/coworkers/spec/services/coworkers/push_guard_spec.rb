require "rails_helper"

RSpec.describe Coworkers::PushGuard do
  let(:coworker) { instance_double(Coworkers::Coworker, id: 7, handle: "maya") }
  subject(:guard) { described_class.new(coworker:) }

  it "allows only the coworker's home, chat, and archive refs" do
    expect(guard.allow!("coworkers/maya")).to eq("coworkers/maya")
    expect(guard.allow!("refs/heads/coworkers/chat/7-42")).to eq("coworkers/chat/7-42")
    expect(guard.allow!("coworkers/archived/maya-2026-10-29-2")).to eq("coworkers/archived/maya-2026-10-29-2")
  end

  it "rejects a foreign ref" do
    expect { guard.allow!("coworkers/ada") }.to raise_error(described_class::ForeignRef)
    expect { guard.allow!("main") }.to raise_error(described_class::ForeignRef)
  end
end
