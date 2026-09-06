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

  it "themes chat-prose pre blocks via CSS variables instead of a hardcoded dark override" do
    expect(css).to include(".chat-prose pre")
    expect(css).to include("background: var(--color-surface-raised)")
    expect(css).to include("color: var(--color-text-primary)")
    expect(css).not_to include(".dark .chat-prose:not(.chat-prose-invert) pre")
  end
end
