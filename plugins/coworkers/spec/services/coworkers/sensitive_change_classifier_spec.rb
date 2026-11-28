require "rails_helper"

RSpec.describe Coworkers::SensitiveChangeClassifier do
  let(:owner) { Factories.user }
  let(:job) { Factories.job_record(user: owner) }

  def classify(*files)
    job.diff_review_versions.create!(version_index: 1, base_sha: "a", head_sha: "b", source_key: "final",
      reason: "source_diff", files_snapshot: files, metadata: {}, truncated: false)
    described_class.call(job)
  end

  it "accepts an ordinary application and regression-spec diff" do
    result = classify({ "path" => "app/services/parser.rb", "patch" => "+fixed" },
      { "path" => "spec/services/parser_spec.rb", "patch" => "+it works" })

    expect(result).not_to be_sensitive
  end

  it "classifies every sensitive path family deterministically" do
    result = classify(
      { "path" => "db/migrate/1_add_flag.rb" }, { "path" => "app/services/permissions/rule.rb" },
      { "path" => "app/models/app_setting_registry.rb" }, { "path" => ".syrus.yml" },
      { "path" => "app/controllers/api/v1/widgets_controller.rb", "patch" => "+  v: 2" }
    )

    expect(result.reasons).to contain_exactly("database migration or schema", "permission or security code",
      "default-setting change", "grader configuration", "top-level JSON API version")
  end
end
