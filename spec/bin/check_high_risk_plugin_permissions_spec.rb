require "rails_helper"

RSpec.describe "high-risk plugin permission cutover gate" do
  let(:script) { Rails.root.join("bin/check-high-risk-plugin-permissions").read }
  let(:configuration) { YAML.safe_load_file(Rails.root.join(".syrus.yml"), aliases: false) }

  it "keeps every migrated family and lifecycle invariant in the required grader" do
    %w[mysql_db_browser k8s_cluster credential_store admin_mysql browser].each do |family|
      expect(script).to include("plugins/#{family}/spec/services/")
    end

    %w[
      shadow_evaluator_spec.rb
      lease_authorizer_spec.rb
      permission_rule_spec.rb
      authorized_invocation_spec.rb
      authorized_invocation_concurrency_spec.rb
    ].each { |invariant| expect(script).to include(invariant) }

    grader = configuration.fetch("grade").find { |entry| entry.fetch("name") == "high-risk-plugin-permissions" }
    expect(grader).to include("required" => true, "phases" => %w[review landing ci])
  end
end
