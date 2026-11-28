require "rails_helper"

RSpec.describe RuntimeImageAuditEvent do
  it "keeps recorded lifecycle evidence immutable" do
    event = described_class.create!(event_type: "publish", outcome: "ok", actor: "operator",
                                    digest: "sha256:#{'a' * 64}", details: { "revision_id" => 7 })

    expect { event.update!(actor: "someone-else") }
      .to raise_error(ActiveRecord::ReadOnlyRecord, /audit evidence is immutable/)
    expect(event.reload).to have_attributes(actor: "operator", details: { "revision_id" => 7 })
  end
end
