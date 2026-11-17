# frozen_string_literal: true

require_relative "deploy_helper"
require "open3"
require "tmpdir"

RSpec.describe Deploy::Repo do
  # Regression: Repo#release_version called ActiveSupport's `presence`. In this
  # suite something else usually has ActiveSupport loaded, so the specs passed,
  # while the real bin/deploy -- which loads no Rails -- crashed with
  # NoMethodError before building any image. Run the code the way the
  # executable does: in a fresh Ruby process with only lib/deploy loaded.
  it "reads release versions in a process without ActiveSupport" do
    Dir.mktmpdir do |dir|
      git = ->(*args) { system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')} failed") }
      git.call("init", "-q")
      git.call("-c", "user.email=spec@example.com", "-c", "user.name=Spec", "commit", "-q", "--allow-empty", "-m", "initial")
      git.call("tag", "v1.2.3")

      script = <<~RUBY
        require_relative #{File.join(DeploySpec::ROOT, "lib/deploy/errors").inspect}
        Dir[#{File.join(DeploySpec::ROOT, "lib/deploy/*.rb").inspect}].sort.each { |path| require path }
        abort "ActiveSupport leaked into the deploy process" if "".respond_to?(:presence)
        reporter = Deploy::Reporter.new(out: StringIO.new, err: StringIO.new)
        repo = Deploy::Repo.new(shell: Deploy::Shell.new(reporter: reporter, chdir: #{dir.inspect}), reporter: reporter)
        puts repo.release_version
        puts repo.version_description
      RUBY

      out, err, status = Open3.capture3(RbConfig.ruby, "-rstringio", "-e", script, chdir: dir)

      expect(status).to be_success, err
      expect(out.lines.map(&:strip)).to eq([ "1.2.3", "1.2.3-0-g#{`git -C #{dir} rev-parse --short HEAD`.strip}" ])
    end
  end
end
