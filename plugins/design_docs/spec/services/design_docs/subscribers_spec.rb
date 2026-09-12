require "rails_helper"

RSpec.describe DesignDocs::Subscribers do
  include ActiveJob::TestHelper

  before do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS design_doc_fts")
    SearchRecord.connection.execute(DesignDocs::SearchSource::TABLE_SQL)
  end

  def event(name, payload)
    Syrus::DomainEvent.new(name: name, payload: payload.stringify_keys)
  end

  it "enqueues an index update when Design Docs search is available" do
    expect {
      described_class.on_design_doc_upserted(event("design_doc.upserted", design_doc_id: 7))
    }.to have_enqueued_job(DesignDocs::IndexSearchJob).with(7).on_queue("indexing")
  end

  it "no-ops when global search is disabled" do
    PluginRecord.find_or_create_by!(name: "global_search").update!(enabled: false, disableable: true)

    expect {
      described_class.on_design_doc_upserted(event("design_doc.upserted", design_doc_id: 7))
      described_class.on_design_doc_deleted(event("design_doc.deleted", design_doc_id: 7))
    }.not_to have_enqueued_job(DesignDocs::IndexSearchJob)
  end

  it "deletes stale rows when a doc is removed" do
    allow(DesignDocs::SearchIndex).to receive(:delete)

    described_class.on_design_doc_deleted(event("design_doc.deleted", design_doc_id: 7))

    expect(DesignDocs::SearchIndex).to have_received(:delete).with(7)
  end

  it "subscribes to the events it handles" do
    expect(described_class.subscriptions.keys).to contain_exactly("design_doc.upserted", "design_doc.deleted")
  end
end
