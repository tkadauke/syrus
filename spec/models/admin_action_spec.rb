require "rails_helper"

RSpec.describe AdminAction do
  let(:user) { Factories.user }

  describe ".log!" do
    it "creates an append-only audit row with action + JSON params + performed_at" do
      record = described_class.log!(user: user, action: :pause_polling, params: { reason: "deploy" })
      expect(record).to be_persisted
      expect(record.user).to eq(user)
      expect(record.action).to eq("pause_polling")
      expect(record.params).to eq("reason" => "deploy")
      expect(record.performed_at).to be_within(2.seconds).of(Time.current)
    end

    # Regression: a merge train's repair snapshots outgrew the MySQL column
    # and the audit insert failed after the action had already run, so the
    # API answered 500 for work that happened.
    it "replaces oversized repair snapshots with their size instead of failing" do
      stub_const("AdminAction::PARAMS_BYTE_LIMIT", 1_000)
      snapshot = { "workflows" => [ { "id" => 1, "state" => "queued", "artifacts" => "x" * 2_000 } ] }

      record = described_class.log!(user: user, action: :pending_action_reenqueue_work,
        params: { reason: "stranded train", before_snapshot: snapshot, after_snapshot: snapshot, result: { "id" => 7 } })

      params = record.reload.params
      expect(params["reason"]).to eq("stranded train")
      expect(params["result"]).to eq("id" => 7)
      expect(params["before_snapshot"]).to include("omitted" => "snapshot exceeded the audit size limit")
      expect(params["after_snapshot"]["bytes"]).to eq(snapshot.to_json.bytesize)
    end

    it "keeps snapshots that fit" do
      snapshot = { "workflows" => [ { "id" => 1 } ] }

      record = described_class.log!(user: user, action: :foo, params: { before_snapshot: snapshot })

      expect(record.reload.params["before_snapshot"]).to eq(snapshot)
    end

    it "rejects updates" do
      record = described_class.log!(user: user, action: :foo)
      expect { record.update!(action: "bar") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "rejects direct destroys" do
      record = described_class.log!(user: user, action: :foo)
      expect { record.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe ".recent" do
    it "returns the latest 50 by performed_at desc" do
      old = described_class.log!(user: user, action: :a, params: {})
      old.update_columns(performed_at: 1.year.ago)  # bypass append-only guard via update_columns
      new = described_class.log!(user: user, action: :b, params: {})
      expect(described_class.recent.first).to eq(new)
    end
  end
end
