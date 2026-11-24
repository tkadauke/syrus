require "rails_helper"

RSpec.describe SyrusCoverage::HitMap do
  let(:workflow) { Factories.job.workflows.first }
  let(:data) { { "app/models/user.rb" => { "1" => 3, "2" => 0 } } }

  it "round-trips a gzipped hit map through the attached blob" do
    described_class.store!(workflow, data)

    expect(described_class.attached_for?(workflow)).to be(true)
    expect(described_class.data_for(workflow)).to eq(data)
  end

  it "replaces the blob when a workflow is analyzed again" do
    described_class.store!(workflow, data)
    described_class.store!(workflow, { "a.rb" => { "1" => 1 } })

    expect(described_class.where(workflow_id: workflow.id).count).to eq(1)
    expect(described_class.data_for(workflow)).to eq({ "a.rb" => { "1" => 1 } })
  end

  it "reports nothing for a workflow without one" do
    expect(described_class.attached_for?(workflow)).to be(false)
    expect(described_class.data_for(workflow)).to be_nil
  end

  it "purges the record and its blob" do
    described_class.store!(workflow, data)

    described_class.purge_for!(workflow)

    expect(described_class.where(workflow_id: workflow.id)).to be_empty
    expect(ActiveStorage::Attachment.where(record_type: "SyrusCoverage::HitMap")).to be_empty
  end

  it "still reads a hit map attached to the Workflow before this plugin owned storage" do
    io = StringIO.new.tap { |buffer| Zlib::GzipWriter.wrap(buffer) { |gz| gz.write(JSON.generate(data)) } }
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(io.string), filename: "coverage_hit_map.json.gz")
    ActiveStorage::Attachment.create!(name: "coverage_hit_map", record_type: "Workflow", record_id: workflow.id, blob: blob)

    expect(described_class.attached_for?(workflow)).to be(true)
    expect(described_class.data_for(workflow)).to eq(data)

    described_class.purge_for!(workflow)
    expect(described_class.attached_for?(workflow)).to be(false)
  end
end
