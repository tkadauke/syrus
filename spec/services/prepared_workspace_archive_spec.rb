require "rails_helper"
require "tmpdir"

RSpec.describe PreparedWorkspaceArchive do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }
  let(:creator_step) { Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "succeeded") }
  let(:snapshot) do
    WorkflowSourceSnapshot.create!(
      workflow: workflow,
      creator_step: creator_step,
      source_sha: "a" * 40,
      source_ref: "refs/heads/main",
      tree_sha: "b" * 40,
      published_at: Time.current
    )
  end
  let(:plan) do
    instance_double(
      RepoPrepPlan::Result,
      source: ".syrus.yml",
      note: nil,
      guessed?: false,
      commands: [ "bundle install" ]
    )
  end
  let(:workspace_dir) { Dir.mktmpdir("prepared-workspace-archive-spec") }

  subject(:archive) do
    described_class.new(workflow: workflow, snapshot: snapshot, step: creator_step, path: workspace_dir, plan: plan)
  end

  before do
    File.write(File.join(workspace_dir, "hello.txt"), "hello world\n" * 200)
    FileUtils.mkdir_p(File.join(workspace_dir, "nested"))
    File.write(File.join(workspace_dir, "nested", "file.txt"), "nested contents\n" * 50)
  end

  after do
    FileUtils.rm_rf(workspace_dir)
  end

  # A directory tar can never read: -C against it fails immediately (exit
  # 2) while the downstream compressor still emits a small valid (but
  # empty/garbage) stream, so the upload itself "succeeds" before the
  # producer failure is detected -- exactly the case the abort/cleanup
  # path exists for.
  let(:missing_path) { File.join(workspace_dir, "does-not-exist") }

  def failing_archive(fixed_key: nil)
    allow(ActiveStorage::Blob).to receive(:generate_unique_secure_token).and_return(fixed_key) if fixed_key
    described_class.new(workflow: workflow, snapshot: snapshot, step: creator_step, path: missing_path, plan: plan)
  end

  # Scoped to archive-shaped filenames rather than the whole tmpdir tree:
  # this box runs other unrelated processes that constantly churn /tmp, so
  # diffing the entire directory listing is flaky. The regression this
  # guards against is specifically a materialized `*.tar.gz` archive file
  # (the old `temporary_archive_path` used a `syrus-prepared-workspace-*`
  # prefix) -- that shape can't collide with unrelated background churn.
  def tmp_snapshot
    Dir.glob(File.join(Dir.tmpdir, "**", "*.tar.gz")).to_set
  end

  describe "compressor selection" do
    it "prefers pigz -1 when pigz is available" do
      allow(described_class).to receive(:pigz_available?).and_return(true)

      expect(archive.send(:compressor_command)).to eq([ "pigz", "-1", "-c" ])
    end

    it "falls back to gzip -1 when pigz is not available" do
      allow(described_class).to receive(:pigz_available?).and_return(false)

      expect(archive.send(:compressor_command)).to eq([ "gzip", "-1", "-c" ])
    end
  end

  describe "against the Disk-backed default service" do
    it "publishes the archive without ever writing a local archive file" do
      before_tmp_files = tmp_snapshot

      expect(archive.publish!).to eq(true)

      expect(tmp_snapshot - before_tmp_files).to be_empty
      expect(snapshot.reload.prepared_workspace_archive).to be_attached
      blob = snapshot.prepared_workspace_archive.blob
      expect(blob.byte_size).to be > 0
      expect(blob.checksum).to be_present
      expect(blob.metadata["sha256"]).to be_present
      expect(blob.metadata["compression_level"]).to eq(1)
    end

    it "is idempotent once metadata already matches the published archive" do
      expect(archive.publish!).to eq(true)
      first_blob_id = snapshot.reload.prepared_workspace_archive.blob.id

      expect(described_class.new(
        workflow: workflow, snapshot: snapshot, step: creator_step, path: workspace_dir, plan: plan
      ).publish!).to eq(false)

      expect(snapshot.reload.prepared_workspace_archive.blob.id).to eq(first_blob_id)
    end

    it "skips upload and leaves no local file when the archive exceeds the size cap" do
      stub_const("PreparedWorkspaceArchive::MAX_BYTES", 1)
      before_tmp_files = tmp_snapshot

      expect(archive.publish!).to eq(false)

      expect(tmp_snapshot - before_tmp_files).to be_empty
      expect(snapshot.reload.prepared_workspace_archive).not_to be_attached
    end

    it "cleans up the already-uploaded object when the tar producer fails" do
      service = ActiveStorage::Blob.service
      allow(service).to receive(:upload).and_call_original
      allow(service).to receive(:delete).and_call_original
      archive = failing_archive(fixed_key: "producer-failure-disk-key")

      expect(archive.publish!).to eq(false)

      expect(service).to have_received(:upload)
      expect(service).to have_received(:delete).with("producer-failure-disk-key")
      expect(service.exist?("producer-failure-disk-key")).to eq(false)
      expect(snapshot.reload.prepared_workspace_archive).not_to be_attached
    end
  end

  describe "against an S3-backed service" do
    let(:s3_client) do
      Aws::S3::Client.new(
        stub_responses: true,
        region: "us-east-1",
        access_key_id: "test-access-key",
        secret_access_key: "test-secret-key"
      )
    end
    let(:s3_service) do
      ActiveStorage::Service::S3Service.new(bucket: "syrus-test-bucket", client: s3_client).tap do |service|
        service.name = "test_s3"
      end
    end

    around do |example|
      previous_service = ActiveStorage::Blob.service
      registry = ActiveStorage::Blob.services
      registry.send(:services)[:test_s3] = s3_service
      ActiveStorage::Blob.service = s3_service
      example.run
    ensure
      ActiveStorage::Blob.service = previous_service
      registry.send(:services).delete(:test_s3)
    end

    it "streams the archive through a real multipart upload without writing a local archive file" do
      before_tmp_files = tmp_snapshot

      expect(archive.publish!).to eq(true)

      expect(tmp_snapshot - before_tmp_files).to be_empty
      operations = s3_client.api_requests.map { |request| request[:operation_name] }
      expect(operations.first(3)).to eq(%i[create_multipart_upload upload_part complete_multipart_upload])

      blob = snapshot.reload.prepared_workspace_archive.blob
      expect(blob.service_name).to eq("test_s3")
      expect(blob.byte_size).to be > 0
      expect(blob.checksum).to be_present
      expect(blob.metadata["sha256"]).to be_present
    end

    it "aborts the multipart upload and attaches nothing when the archive exceeds the size cap" do
      stub_const("PreparedWorkspaceArchive::MAX_BYTES", 1)
      before_tmp_files = tmp_snapshot

      expect(archive.publish!).to eq(false)

      expect(tmp_snapshot - before_tmp_files).to be_empty
      operations = s3_client.api_requests.map { |request| request[:operation_name] }
      expect(operations).to include(:abort_multipart_upload)
      expect(operations).not_to include(:complete_multipart_upload)
      expect(snapshot.reload.prepared_workspace_archive).not_to be_attached
    end

    it "aborts the multipart upload when a part upload fails" do
      s3_client.stub_responses(:upload_part, "InternalError")
      before_tmp_files = tmp_snapshot

      expect(archive.publish!).to eq(false)

      expect(tmp_snapshot - before_tmp_files).to be_empty
      operations = s3_client.api_requests.map { |request| request[:operation_name] }
      expect(operations).to include(:abort_multipart_upload)
      expect(snapshot.reload.prepared_workspace_archive).not_to be_attached
    end

    it "completes the multipart upload but deletes the object once a tar producer failure is detected" do
      archive = failing_archive(fixed_key: "producer-failure-s3-key")

      expect(archive.publish!).to eq(false)

      operations = s3_client.api_requests.map { |request| request[:operation_name] }
      expect(operations).to eq(%i[create_multipart_upload upload_part complete_multipart_upload delete_object])
      expect(s3_client.api_requests.last[:params][:key]).to eq("producer-failure-s3-key")
      expect(snapshot.reload.prepared_workspace_archive).not_to be_attached
    end
  end
end
