require "rails_helper"

RSpec.describe "chat prose CSS" do
  let(:css) { Rails.root.join("app/assets/tailwind/application.css").read }

  it "defines dark-mode overrides for markdown selectors" do
    expect(css).to include(".dark .chat-prose:not(.chat-prose-invert) a")
    expect(css).to include(".dark .chat-prose:not(.chat-prose-invert) code")
    expect(css).to include(".dark .chat-prose:not(.chat-prose-invert) blockquote")
    expect(css).to include(".dark .chat-prose:not(.chat-prose-invert) hr")
    expect(css).to include(".dark .chat-prose:not(.chat-prose-invert) td")
    expect(css).to include(".dark .chat-prose:not(.chat-prose-invert) th")
  end

  it "themes chat-prose pre via CSS variables instead of a hardcoded dark override" do
    expect(css).to include("--color-surface-raised")
    expect(css).not_to include(".dark .chat-prose:not(.chat-prose-invert) pre")
  end

  it "lets markdown tables fill prose width before horizontal scrolling" do
    table_rule = css[/\.chat-prose table \{[^}]+\}/]
    wrapper_rule = css[/\.chat-prose-table-wrap \{[^}]+\}/]

    expect(table_rule).to include("width: 100%")
    expect(table_rule).to include("max-width: 100%")
    expect(table_rule).not_to include("width: max-content")
    expect(wrapper_rule).to include("min-width: 0")
    expect(wrapper_rule).to include("overflow-x: auto")
  end

  it "keeps wide markdown blocks from expanding the viewport" do
    prose_rule = css[/\.chat-prose \{[^}]+\}/]
    pre_rule = css[/\.chat-prose pre \{[^}]+\}/]

    expect(prose_rule).to include("min-width: 0")
    expect(prose_rule).to include("max-width: 100%")
    expect(pre_rule).to include("max-width: 100%")
    expect(pre_rule).to include("overflow-x: auto")
  end
end
