require "rails_helper"

# Moving a doc into a plugin must not leave a dangling relative link behind in
# core docs; cross-references to plugin docs are plain path mentions.
RSpec.describe "core syrus_docs relative links" do
  it "only link to Markdown files that exist next to the linking doc" do
    dangling = Rails.root.glob("config/syrus_docs/*.md").flat_map do |doc|
      doc.read.scan(/\]\(([A-Za-z0-9_\-]+\.md)(?:#[^)]*)?\)/).flatten.filter_map do |target|
        "#{doc.basename}: #{target}" unless doc.dirname.join(target).exist?
      end
    end

    expect(dangling).to be_empty
  end
end
