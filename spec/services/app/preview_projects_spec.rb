require "rails_helper"

RSpec.describe App::PreviewProjects do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) { Factories.job_record(repository: repository, user: user, branch_name: "feature", state: "implemented") }
  let(:main_files) { {} }

  # The default-branch TargetGraph and the Job branch diff are both read
  # through RepositoryContent rather than the repository's local bare clone
  # (`RepositoryBareClone`): PreviewProjects is read from web-tier request
  # paths (JobPreviewController, TargetGraphsController), and web pods don't
  # mount the worker's on-disk bare clone (see "Deploy target" in CLAUDE.md
  # — "Web pods don't need this volume"). No $SYRUS_DATA_ROOT clone is
  # created anywhere in this spec, simulating that environment.
  def described(job)
    described_class.new(job)
  end

  def stub_tree(paths)
    paths.each { |path| main_files[path] ||= "" }
    stub_repository_content(repository, files: main_files)
  end

  def stub_syrus_yml(path, content)
    main_files[path] = content
    stub_repository_content(repository, files: main_files)
  end

  def stub_changed_files(paths)
    stub_repository_changes(repository, head: job.branch_name, paths: paths)
  end

  def reads
    FakeRepositoryContentProvider.calls.select { |call| call.first == :read }
  end

  it "returns the one affected nested preview project" do
    stub_tree(%w[apps/web/.syrus.yml apps/api/.syrus.yml apps/web/index.tsx])
    stub_syrus_yml("apps/web/.syrus.yml", "project:\n  id: web\n  label: Web\npreview:\n  start: npm run dev\n")
    stub_syrus_yml("apps/api/.syrus.yml", "project:\n  id: api\n  label: API\npreview:\n  start: bin/server\n")
    stub_changed_files(%w[apps/web/index.tsx])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to eq([ "web" ])
    expect(result.unavailable_reason).to be_nil
  end

  it "returns multiple affected preview projects when the diff spans them" do
    stub_tree(%w[apps/web/.syrus.yml apps/admin/.syrus.yml apps/web/index.tsx apps/admin/index.tsx])
    stub_syrus_yml("apps/web/.syrus.yml", "project:\n  id: web\n  label: Web\npreview:\n  start: npm run dev\n")
    stub_syrus_yml("apps/admin/.syrus.yml", "project:\n  id: admin\n  label: Admin\npreview:\n  start: npm run dev\n")
    stub_changed_files(%w[apps/web/index.tsx apps/admin/index.tsx])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to match_array(%w[web admin])
  end

  it "reports when no affected project has a preview" do
    stub_tree(%w[apps/web/.syrus.yml docs/readme.md])
    stub_syrus_yml("apps/web/.syrus.yml", "project:\n  id: web\npreview:\n  start: npm run dev\n")
    stub_changed_files(%w[docs/readme.md])

    result = described(job).for_job

    expect(result.choices).to eq([])
    expect(result.unavailable_reason).to eq("no_affected_preview_project")
  end

  it "preserves legacy root preview behavior" do
    stub_tree([ ".syrus.yml", "app/models/user.rb" ])
    stub_syrus_yml(".syrus.yml", "preview:\n  start: bin/dev\n")
    stub_changed_files(%w[app/models/user.rb])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to eq([ "repo" ])
    expect(result.choices.first.label).to eq("Repository")
  end

  it "does not include the root preview for files owned by a nested preview project" do
    stub_tree([ ".syrus.yml", "desktop/.syrus.yml", "desktop/src/App.tsx" ])
    stub_syrus_yml(".syrus.yml", "preview:\n  start: bin/dev\n")
    stub_syrus_yml("desktop/.syrus.yml", "project:\n  id: desktop\n  label: Desktop App\npreview:\n  start: npm run dev\n")
    stub_changed_files(%w[desktop/src/App.tsx])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to eq([ "desktop" ])
  end

  it "includes root and nested previews when a diff touches both ownership scopes" do
    stub_tree([ ".syrus.yml", "desktop/.syrus.yml", "app/models/job.rb", "desktop/src/App.tsx" ])
    stub_syrus_yml(".syrus.yml", "preview:\n  start: bin/dev\n")
    stub_syrus_yml("desktop/.syrus.yml", "project:\n  id: desktop\npreview:\n  start: npm run dev\n")
    stub_changed_files(%w[app/models/job.rb desktop/src/App.tsx])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to match_array(%w[repo desktop])
  end

  it "falls back to legacy root behavior when repository content cannot be read" do
    stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("rate limited"))
    allow(Syrus::Plugin::PreviewProvider).to receive(:configured?).and_return(true)

    result = described_class.for_job(job)

    expect(result.choices.map(&:id)).to eq([ "repo" ])
  end

  it "offers every preview project when the branch diff cannot be read" do
    stub_tree(%w[apps/web/.syrus.yml apps/api/.syrus.yml])
    stub_syrus_yml("apps/web/.syrus.yml", "project:\n  id: web\npreview:\n  start: npm run dev\n")
    stub_syrus_yml("apps/api/.syrus.yml", "project:\n  id: api\npreview:\n  start: bin/server\n")

    result = described(job).for_job

    expect(result.choices.map(&:id)).to match_array(%w[web api])
  end

  describe "caching the default-branch graph" do
    # Test runs on :null_store, which would make every assertion below pass
    # vacuously; the cache under test needs a store that actually stores.
    around do |example|
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original
    end

    let(:web_yml) { "project:\n  id: web\n  label: Web\npreview:\n  start: npm run dev\n" }

    # The Job detail page polls, and every poll used to fetch each
    # `.syrus.yml` in the repository one at a time -- 43 serial GitHub calls
    # for a repo shaped like Syrus's own, ~12k requests an hour from one open
    # tab, enough to push the App into rate limiting.
    it "compiles once and serves repeat requests without refetching the configs" do
      stub_syrus_yml("apps/web/.syrus.yml", web_yml)
      stub_tree(%w[apps/web/index.tsx])
      stub_changed_files(%w[apps/web/index.tsx])
      allow(TargetGraph::Compiler).to receive(:compile).and_call_original

      3.times { expect(described(job).for_job.choices.map(&:id)).to eq([ "web" ]) }

      expect(reads.size).to eq(1)
      expect(TargetGraph::Compiler).to have_received(:compile).once
    end

    # Keyed on the configs' content ids, so a changed `.syrus.yml` is a new
    # key and is recompiled as soon as the default branch is re-resolved --
    # never served stale until a TTL runs out.
    it "recompiles as soon as a .syrus.yml changes" do
      stub_syrus_yml("apps/web/.syrus.yml", web_yml)
      stub_changed_files(%w[apps/web/index.tsx])
      expect(described(job).for_job.choices.map(&:label)).to eq([ "Web" ])

      stub_syrus_yml("apps/web/.syrus.yml", web_yml.sub("label: Web", "label: Web App"))

      travel(RepositoryContent::DEFAULT_MAX_AGE.seconds + 1.second) do
        expect(described(job).for_job.choices.map(&:label)).to eq([ "Web App" ])
      end
    end

    # A commit that touches no `.syrus.yml` moves main but changes nothing the
    # graph depends on -- which is nearly every commit.
    it "keeps serving the cached graph across commits that touch no config" do
      stub_syrus_yml("apps/web/.syrus.yml", web_yml)
      stub_tree(%w[apps/web/index.tsx])
      stub_changed_files(%w[apps/web/index.tsx])
      described(job).for_job

      main_files["apps/web/index.tsx"] = "v2"
      stub_repository_content(repository, files: main_files)
      travel(RepositoryContent::DEFAULT_MAX_AGE.seconds + 1.second) { described(job).for_job }

      expect(reads.size).to eq(1)
    end

    # The cache key describes the files at the tree's revision, so they must
    # be read there too -- never at a branch name that may have moved.
    it "reads configs at the revision the tree came from" do
      revision = stub_syrus_yml("apps/web/.syrus.yml", web_yml)
      stub_changed_files(%w[apps/web/index.tsx])

      described(job).for_job

      expect(reads).to eq([ [ :read, revision.id, "apps/web/.syrus.yml" ] ])
    end

    # With no content id there is no exact key. Caching under a guessed one
    # would keep serving the old graph after a config change.
    it "does not cache the graph when tree entries carry no content id" do
      stub_repository_content(repository, files: { "apps/web/.syrus.yml" => web_yml }, content_ids: false)
      stub_changed_files(%w[apps/web/index.tsx])
      allow(TargetGraph::Compiler).to receive(:compile).and_call_original

      2.times { described(job).for_job }

      expect(TargetGraph::Compiler).to have_received(:compile).twice
    end
  end
end
