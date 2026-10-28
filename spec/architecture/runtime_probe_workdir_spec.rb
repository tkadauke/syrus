require "rails_helper"

# `ProcessRunner#capture` creates a temporary directory for its named pipes
# under the runner's workdir, so a probe mounted at `Dir.pwd` needs the
# application root to be writable. In the deployed image it is not, and the
# resulting Errno::EACCES does not announce itself as a permission problem --
# it surfaces as "tool not available", or as the caller failing for an
# unrelated-looking reason. One such probe silently disabled cross-workflow
# prepared-layer reuse fleet-wide: every grader fanout re-ran the full
# dependency prepare on every host because a compressor probe could not make
# a directory.
#
# Probes have no workspace of their own, so they all use
# `ProcessRunner.probe_mounts`.
RSpec.describe "runtime probe working directories" do
  ROOTS = %w[app lib plugins].freeze

  def probe_construction_sources
    Dir.glob(ROOTS.map { |root| Rails.root.join(root, "**", "*.rb").to_s })
      .reject { |path| path.include?("/spec/") }
      .select { |path| File.read(path).include?(%(kind: "runtime_probe")) }
  end

  it "mounts every runtime probe somewhere writable instead of the application root" do
    offenders = probe_construction_sources.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.include?("mounts:")
        next unless line.match?(/mounts:\s*ProcessRunner\.mounts\(\s*Dir\.pwd/)

        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{index + 1}"
      end
    end

    expect(offenders).to be_empty, lambda {
      "use ProcessRunner.probe_mounts for runtime probes:\n#{offenders.join("\n")}"
    }
  end

  it "finds the probe call sites it claims to audit" do
    # Without this the example above passes when the grep stops matching.
    expect(probe_construction_sources.size).to be >= 3
  end

  describe "ProcessRunner.probe_workdir" do
    it "is a writable directory under the worker data root" do
      workdir = ProcessRunner.probe_workdir

      expect(workdir.to_s).to start_with(WorkflowWorkspace.data_root.to_s)
      expect(workdir).to be_directory
      expect(File.writable?(workdir)).to be(true)
    end

    it "falls back to a usable directory when the data root cannot be created" do
      allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES, "data root")

      expect(File.writable?(ProcessRunner.probe_workdir)).to be(true)
    end
  end
end
