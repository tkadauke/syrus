require "tmpdir"

# Give every spec process its own $SYRUS_DATA_ROOT, outside the checkout.
#
# WorkflowWorkspace.data_root falls back to ~/.syrus when SYRUS_DATA_ROOT is
# unset, so the suite wrote workspaces, clones, and previews into the
# operator's real data directory. Under parallel_tests that is a correctness
# problem, not just untidiness: each worker has its own database, so several
# workers create Workflow id 1 at the same time and all resolve to
# ~/.syrus/workflows/1. Whichever tore its directory down first made the others
# fail with ENOENT or EINVAL -- the intermittent start_preview and
# branch-divergence failures.
#
# It has to live outside the repository. Git commands run with chdir into a
# workspace path, and git walks up the directory tree looking for a repo: a
# data root under Rails.root means a leftover workspace directory resolves to
# the Syrus checkout itself, so `git rev-parse main` quietly returns a real SHA
# instead of failing and letting the caller fall back. That is the same reason
# production keeps clones outside the operator's checkout.
#
# Keyed by parallel worker and pid so two suites running at once cannot collide.
SPEC_DATA_ROOT = Pathname.new(Dir.tmpdir).join(
  "syrus-spec-data-root",
  "worker#{ENV['TEST_ENV_NUMBER'].presence || '1'}-#{Process.pid}"
).freeze

ENV["SYRUS_DATA_ROOT"] ||= SPEC_DATA_ROOT.to_s

RSpec.configure do |config|
  config.before(:suite) do
    FileUtils.rm_rf(SPEC_DATA_ROOT)
    FileUtils.mkdir_p(SPEC_DATA_ROOT)
  end

  config.after(:suite) do
    FileUtils.rm_rf(SPEC_DATA_ROOT)
  end
end
