require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::CoworkerReviewProjects do
  it "collects criteria only from affected project configurations" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".syrus.yml"), <<~YAML)
        coworker_review:
          enabled: true
          rounds: 1
          criteria: [root rule]
      YAML
      FileUtils.mkdir_p(File.join(dir, "api"))
      File.write(File.join(dir, "api", ".syrus.yml"), <<~YAML)
        project:
          id: api
        coworker_review:
          enabled: true
          rounds: 1
          criteria: [api product rule]
      YAML

      result = described_class.call(workspace_path: dir, changed_files: [ "api/controller.rb" ])
      expect(result.criteria).to eq([ "root rule", "api product rule" ])
    end
  end
end
