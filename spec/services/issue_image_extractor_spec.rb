require "rails_helper"

RSpec.describe IssueImageExtractor do
  it "extracts inline Markdown image URLs and deduplicates them" do
    markdown = <<~MD
      ![first](https://user-images.githubusercontent.com/1/screen.png)
      ![duplicate](https://user-images.githubusercontent.com/1/screen.png)
      ![angle](<https://github.com/user-attachments/assets/abc-123>)
      [regular link](https://example.com/not-an-image.png)
    MD

    expect(described_class.urls(markdown)).to eq([
      "https://user-images.githubusercontent.com/1/screen.png",
      "https://github.com/user-attachments/assets/abc-123"
    ])
  end

  it "ignores invalid and non-http image targets" do
    markdown = "![bad](nota url) ![local](file:///tmp/screen.png)"

    expect(described_class.urls(markdown)).to be_empty
  end
end
