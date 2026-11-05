# frozen_string_literal: true

# OPERATOR DESIGN LOCK — DO NOT REMOVE, WEAKEN, REWRITE, OR UPDATE THESE
# ASSERTIONS/FIXTURES TO PERMIT A MULTI-LINE COLLAPSED TOOL CARD WITHOUT
# EXPLICIT WRITTEN APPROVAL FROM THOMAS KADAUKE. A collapsed tool card is
# exactly one visual line at every width: title without a line break, then
# pills, then a clipped/ellipsized details preview. Full details belong only
# in the expanded state.
RSpec.describe "collapsed tool group header design lock" do
  subject(:implementation) do
    source = Rails.root.join("app/frontend/routes/chat/MessageCards.tsx").read
    source.match(/function CollapsedToolGroupHeader.*?^}/m)&.[](0) || raise("CollapsedToolGroupHeader implementation not found")
  end

  it "keeps the shared header a single non-wrapping row with a clipped preview" do
    expect(implementation).to include('className="flex min-w-0 max-w-full')
    expect(implementation).to include("overflow-hidden whitespace-nowrap")
    expect(implementation).to include('data-testid="tool-group-preview"')
    expect(implementation).to include("min-w-0 flex-1 truncate")
  end

  it "rejects mechanisms that can create alternate or wrapping rows" do
    expect(implementation).not_to match(/\b(?:flex-wrap|break-words|whitespace-normal)\b/)
    expect(implementation).not_to match(/\[overflow-wrap:anywhere\]/)
    expect(implementation).not_to match(/\b(?:grid|grid-cols-|col-start-|col-end-)\S*/)
    expect(implementation).not_to match(/\b(?:sm|md|lg|xl|2xl):\S+/)
  end
end
