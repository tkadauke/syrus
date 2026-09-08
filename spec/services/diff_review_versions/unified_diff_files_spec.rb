require "rails_helper"

RSpec.describe DiffReviewVersions::UnifiedDiffFiles do
  it "extracts per-file patch snapshots from a unified diff" do
    diff = <<~DIFF
      diff --git a/app/models/user.rb b/app/models/user.rb
      index 1111111..2222222 100644
      --- a/app/models/user.rb
      +++ b/app/models/user.rb
      @@ -1,2 +1,3 @@
       class User
      +  def active? = true
       end
      diff --git a/app/models/old.rb b/app/models/old.rb
      deleted file mode 100644
      index 3333333..0000000
      --- a/app/models/old.rb
      +++ /dev/null
      @@ -1 +0,0 @@
      -class Old; end
    DIFF

    expect(described_class.parse(diff)).to eq([
      {
        path: "app/models/user.rb",
        status: "modified",
        additions: 1,
        deletions: 0,
        patch: "@@ -1,2 +1,3 @@\n class User\n+  def active? = true\n end\n"
      },
      {
        path: "app/models/old.rb",
        status: "removed",
        additions: 0,
        deletions: 1,
        patch: "@@ -1 +0,0 @@\n-class Old; end\n"
      }
    ])
  end
end
