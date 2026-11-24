require "rails_helper"

# The review_plan step, its handler, prompt, tool and `.syrus.yml` key belong to
# the review_planning plugin. Core must not name them.
RSpec.describe "Review plan plugin boundary" do
  OWNED_REVIEW_PLAN_NAMES = /\breview_plan\b|(?<![A-Za-z])ReviewPlan\b/

  # Unrelated core names that merely contain the words.
  ALLOWED_REVIEW_PLAN_PATHS = %w[
    app/services/repo_adversarial_review_plan.rb
    app/services/repo_security_review_plan.rb
  ].freeze

  it "keeps review_plan out of core Ruby and config" do
    roots = %w[app lib config bin].map { |dir| Rails.root.join(dir) }
    files = roots.flat_map { |root| Dir.glob(root.join("**/*.{rb,yml,rake}")) }
                 .reject { |path| path.include?("/app/frontend/") || path.include?("/config/syrus_docs/") }
                 .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
    offenders = files.filter_map do |path|
      next if ALLOWED_REVIEW_PLAN_PATHS.include?(path)

      Rails.root.join(path).read.lines.each_with_index.filter_map { |line, i| "#{path}:#{i + 1}" if line.match?(OWNED_REVIEW_PLAN_NAMES) }.first
    end

    expect(offenders).to be_empty, "review_plan belongs in plugins/review_planning: #{offenders.join(', ')}"
  end

  it "keeps the step kind in the plugin, not in core's Step::Kind" do
    expect(Step::Kind::BUILT_IN_ENTRIES.map(&:kind)).not_to include("review_plan")
  end
end
