# Refactor ChatProposalFiler proposal.kind dispatch to a registry

**Severity**: Medium — 4-branch case on an extensible proposal kind; new proposal types (already being discussed) would silently fall through to the `raise ArgumentError` without a test.

## Problem

`ChatProposalFiler#file_proposal` switches on `proposal.kind` (`app/services/chat_proposal_filer.rb`, lines 102–112):

```ruby
case proposal.kind
when "syrus_issue", "job"
  create_direct_job!(proposal)
when "github_issue"
  file_github_issue!(proposal)
when "epic"
  create_epic!(proposal)
else
  raise ArgumentError, "unsupported proposal kind: #{proposal.kind}"
end
```

`ChatProposal` has four valid kinds (`syrus_issue`, `github_issue`, `epic`, `job` — enum defined at `app/models/chat_proposal.rb:46`). The `ChatProposalFiler` has to know about all of them explicitly. When a new proposal kind is added to the enum, the developer must also update this case statement or hit the runtime `ArgumentError`.

The same class also has a secondary dispatch in `#materialize_proposal` (`app/services/chat_proposal_filer.rb`, lines 35–47):

```ruby
case materialized
when Job   then # ...
when Epic  then # ...
when nil   then # ...
```

This one dispatches on the *result type* rather than the kind string — slightly different shape, but the same smell.

## Target design

### Registry on ChatProposal

```ruby
# app/models/chat_proposal.rb — add class-level filing handler lookup
module ChatProposal::Filers
  REGISTRY = {}.freeze

  def self.for(kind)
    REGISTRY[kind.to_s] or raise ArgumentError, "unsupported proposal kind: #{kind}"
  end

  def self.register(kind, klass)
    REGISTRY[kind.to_s] = klass
  end
end
```

### Handler interface

```ruby
# app/services/chat_proposal_filers/base.rb
module ChatProposalFilers
  class Base
    def initialize(proposal, filer:)
      @proposal = proposal
      @filer = filer
    end

    def call
      raise NotImplementedError
    end
  end
end
```

### Handler per kind

```ruby
# app/services/chat_proposal_filers/direct_job.rb
module ChatProposalFilers
  class DirectJob < Base
    ChatProposal::Filers.register("syrus_issue", self)
    ChatProposal::Filers.register("job", self)

    def call
      @filer.create_direct_job!(@proposal)
    end
  end
end

# app/services/chat_proposal_filers/github_issue.rb
module ChatProposalFilers
  class GithubIssue < Base
    ChatProposal::Filers.register("github_issue", self)

    def call
      @filer.file_github_issue!(@proposal)
    end
  end
end

# app/services/chat_proposal_filers/epic.rb
module ChatProposalFilers
  class EpicFiler < Base
    ChatProposal::Filers.register("epic", self)

    def call
      @filer.create_epic!(@proposal)
    end
  end
end
```

### Updated caller

```ruby
# ChatProposalFiler#file_proposal
ChatProposal::Filers.for(proposal.kind).new(proposal, filer: self).call
```

## Files to create

- `app/services/chat_proposal_filers/base.rb`
- `app/services/chat_proposal_filers/direct_job.rb`
- `app/services/chat_proposal_filers/github_issue.rb`
- `app/services/chat_proposal_filers/epic.rb`

## Files to update

- `app/models/chat_proposal.rb` — add `Filers` registry submodule
- `app/services/chat_proposal_filer.rb` — replace case with registry lookup

## Tests needed

- Registry raises `ArgumentError` for unknown kind
- Each handler routes to the correct `ChatProposalFiler` private method
- Existing integration specs for proposal filing still pass

## Out of scope

- Changing what `create_direct_job!`, `file_github_issue!`, or `create_epic!` do
- Moving the `#materialize_proposal` result-type dispatch in the same PR (separate, smaller problem)
- Adding new proposal kinds as part of this refactor
