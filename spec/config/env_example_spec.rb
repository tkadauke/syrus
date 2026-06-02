require "rails_helper"

RSpec.describe ".env.example" do
  let(:env_example_path) { Rails.root.join(".env.example") }
  let(:env_example) { env_example_path.read }

  def env_names_from(path)
    text = Rails.root.join(path).read
    text.scan(/ENV(?:\[\s*["']([^"']+)["']\s*\]|\.fetch\(\s*["']([^"']+)["']|\.key\?\(\s*["']([^"']+)["']|\.include\?\(\s*["']([^"']+)["'])/)
      .flatten
      .compact
      .concat(text.scan(/env_boolean\.call\(\s*["']([^"']+)["']/).flatten)
  end

  it "documents every env var referenced by the required config surfaces" do
    documented = env_example.scan(/^([A-Z][A-Z0-9_]*)=/).flatten
    required = %w[
      RAILS_MASTER_KEY
      SOLID_QUEUE_IN_PUMA
      SYRUS_GITHUB_REPO
      SYRUS_BUG_REPORT_OWNER
    ]

    required.concat(env_names_from("config/environments/development.rb"))
    required.concat(env_names_from("config/environments/production.rb"))
    required.concat(env_names_from("config/environments/test.rb"))
    required.concat(env_names_from("config/database.yml"))
    required.concat(env_names_from("config/storage.yml"))
    required.concat(env_names_from("config/deploy.yml"))

    expect(documented).to include(*required.uniq.sort)
  end

  it "keeps a short inline comment on each assignment" do
    assignments = env_example.lines.grep(/\A[A-Z][A-Z0-9_]*=/)

    expect(assignments).not_to be_empty
    expect(assignments).to all(match(/\s#\s\S/))
  end
end
