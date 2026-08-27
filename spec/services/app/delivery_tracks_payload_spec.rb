require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::DeliveryTracksPayload do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def write_bare_clone(repository, syrus_yml: nil)
    work_dir = Dir.mktmpdir("syrus-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    File.write(File.join(work_dir, "README.md"), "hi") unless syrus_yml
    File.write(File.join(work_dir, ".syrus.yml"), syrus_yml) if syrus_yml
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

    clone_path = RepositoryBareClone.path_for(repository)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  it "returns nil for a repository with no delivery config beyond the implicit default track" do
    write_bare_clone(repository)

    expect(described_class.for(repository: repository)).to be_nil
  end

  it "returns tracks, ref-movement actions, recent workflows, and PR ingestions for a configured repository" do
    write_bare_clone(repository, syrus_yml: <<~YAML)
      delivery:
        tracks:
          default:
            branch: develop
          hotfix:
            branch: release
        promotion:
          enabled: true
          mode: manual_pr
        ref_movement_actions:
          send_job_upstream:
            enabled: true
            mode: manual_pr
            source: { kind: job_branch }
            target: { kind: upstream_intake }
    YAML

    landed = Factories.job_record(repository: repository, issue_number: 1, state: "approved")
    Workflow.create!(
      job: landed,
      trigger_kind: "promotion",
      state: "succeeded",
      artifacts: { "promotion_source_branch" => "develop", "promotion_target_branch" => "main" }
    )
    JobPrLink.create!(job: landed, role: JobPrLink::ROLE_PROMOTION, source_ref: "develop", target_ref: "main", pr_number: 5, metadata: { "pr_state" => "open" })
    landed.update_columns(state: "closed", closure_reason: "pr_merged")

    queued_on_hotfix = Factories.job_record(repository: repository, issue_number: 2, state: "approved", delivery_track: "hotfix")

    external_job = Job.create!(
      user: repository.user,
      repository: repository,
      kind: "external_pr",
      state: "implemented",
      issue_number: nil,
      external_pr_number: 9,
      branch_name: "feature"
    )
    JobPrLink.create!(
      job: external_job,
      role: JobPrLink::ROLE_EXTERNAL_INGEST,
      target_repository_id: repository.id,
      source_ref: "feature",
      target_ref: "develop",
      pr_number: 9,
      metadata: { "provenance" => "syrus_job_export" }
    )

    payload = described_class.for(repository: repository)
    expect(payload).not_to be_nil

    track_names = payload[:tracks].map { |track| track[:name] }
    expect(track_names).to contain_exactly("default", "hotfix")

    default_track = payload[:tracks].find { |track| track[:name] == "default" }
    expect(default_track[:branch]).to eq("develop")
    expect(default_track[:is_default]).to be(true)
    expect(default_track[:last_promotion]).to include(source_ref: "develop", target_ref: "main")

    hotfix_track = payload[:tracks].find { |track| track[:name] == "hotfix" }
    expect(hotfix_track[:branch]).to eq("release")
    expect(hotfix_track[:queue_length]).to eq(1)
    expect(hotfix_track[:last_promotion]).to be_nil

    expect(payload[:ref_movement_actions]).to contain_exactly(
      a_hash_including(name: "send_job_upstream", enabled: true, mode: "manual_pr")
    )

    workflow_entry = payload[:recent_ref_movement_workflows].find { |entry| entry[:job_id] == landed.id }
    expect(workflow_entry).to include(trigger_kind: "promotion", source_ref: "develop", target_ref: "main", pr_number: 5, pr_state: "open")

    ingestion_entry = payload[:recent_pr_ingestions].find { |entry| entry[:job_id] == external_job.id }
    expect(ingestion_entry).to include(pr_number: 9, classification: "syrus_job_export")

    expect(queued_on_hotfix).to be_present
  end

  it "defaults PR ingestion classification to external_unknown when no provenance link exists" do
    write_bare_clone(repository, syrus_yml: <<~YAML)
      delivery:
        upstream_export:
          enabled: true
    YAML

    external_job = Job.create!(
      user: repository.user,
      repository: repository,
      kind: "external_pr",
      state: "implemented",
      issue_number: nil,
      external_pr_number: 11,
      branch_name: "some-branch"
    )

    payload = described_class.for(repository: repository)
    ingestion_entry = payload[:recent_pr_ingestions].find { |entry| entry[:job_id] == external_job.id }

    expect(ingestion_entry[:classification]).to eq("external_unknown")
  end
end
