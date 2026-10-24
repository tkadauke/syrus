require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::SecurityReviewProjects do
  it "collects criteria only from affected project configurations" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".syrus.yml"), "security_review:\n  rounds: 1\n  criteria: [root rule]\n")
      FileUtils.mkdir_p(File.join(dir, "api"))
      File.write(File.join(dir, "api", ".syrus.yml"), "project:\n  id: api\nsecurity_review:\n  rounds: 1\n  criteria: [api auth rule]\n")

      result = described_class.call(workspace_path: dir, changed_files: [ "api/controller.rb" ])
      expect(result.criteria).to eq([ "root rule", "api auth rule" ])
    end
  end
end
