# Extract provider dispatch in DirectJobTitleGenerator and IngestionClassifier into AgentProviders

**Severity**: Medium — two utility services bypass the existing `AgentProviders` registry and duplicate provider-specific invocation setup; adding a third provider would require updating both.

## Problem

`AgentProviders::*` already handles provider dispatch for workflow runs (`Steps::Base` uses it). But two services that run short one-shot agent calls re-implement the dispatch by hand:

### 1. `DirectJobTitleGenerator#run_once` — lines 120–155 (`app/services/direct_job_title_generator.rb`)

```ruby
case @provider
when "claude"
  ClaudeInvocation.new(
    workspace_path,
    prompt: prompt,
    oauth_token: @user.claude_oauth_token,
    log_sink: log_sink,
    runner: @runner,
    timeout: timeout,
    max_turns: max_turns
  ).run
when "codex"
  codex_home = File.join(
    WorkflowWorkspace.data_root, "agent_homes", "direct_job_title",
    @user.id.to_s, "codex"
  )
  CodexAuth.with_refresh_lock(user: @user) do
    codex_auth = CodexAuth.new(user: @user, codex_home: codex_home)
    auth = codex_auth.prepare!
    begin
      CodexInvocation.new(
        workspace_path, prompt: prompt, api_key: auth.api_key,
        log_sink: log_sink, runner: @runner, timeout: timeout,
        codex_home: codex_home
      ).run
    ensure
      codex_auth.persist_updated_auth_json
    end
  end
```

### 2. `IngestionClassifier#run_once` — lines 240–272 (`app/services/ingestion_classifier.rb`)

Near-identical structure: `case @provider / when "claude" / ClaudeInvocation / when "codex" / CodexAuth + CodexInvocation`.

Both services duplicate:
- Auth token lookup (`claude_oauth_token`, Codex `CodexAuth` dance)
- `codex_home` path construction
- The `CodexAuth.with_refresh_lock` + `persist_updated_auth_json` lifecycle
- The `AgentProviders::ConfigurationError` fallback

If a third provider is added (and the `AgentProviders` registry gets it), both services would need manual updates or they'd silently fail with the `else` branch.

## Target design

Extend `AgentProviders` (or add a lightweight adapter) so the registry handles one-shot invocations too.

### Proposed interface

```ruby
# app/services/agent_providers/base.rb — add a one_shot method
module AgentProviders
  class Base
    def one_shot(workspace_path, prompt:, log_sink:, runner:, timeout:, max_turns:)
      raise NotImplementedError
    end
  end
end

# app/services/agent_providers/claude.rb
module AgentProviders
  class Claude < Base
    def one_shot(workspace_path, prompt:, log_sink:, runner:, timeout:, max_turns:)
      ClaudeInvocation.new(
        workspace_path,
        prompt: prompt,
        oauth_token: @user.claude_oauth_token,
        log_sink: log_sink,
        runner: runner,
        timeout: timeout,
        max_turns: max_turns
      ).run
    end
  end
end

# app/services/agent_providers/codex.rb
module AgentProviders
  class Codex < Base
    def one_shot(workspace_path, prompt:, log_sink:, runner:, timeout:, max_turns:)
      codex_home = File.join(WorkflowWorkspace.data_root, "agent_homes", @scope, @user.id.to_s, "codex")
      CodexAuth.with_refresh_lock(user: @user) do
        codex_auth = CodexAuth.new(user: @user, codex_home: codex_home)
        auth = codex_auth.prepare!
        begin
          CodexInvocation.new(
            workspace_path, prompt: prompt, api_key: auth.api_key,
            log_sink: log_sink, runner: runner, timeout: timeout,
            codex_home: codex_home
          ).run
        ensure
          codex_auth.persist_updated_auth_json
        end
      end
    end
  end
end
```

The `@scope` parameter (`"direct_job_title"`, `"ingestion_classifier"`) keeps `codex_home` paths stable.

### Updated callers

```ruby
# DirectJobTitleGenerator#run_once
adapter = AgentProviders.for(@provider).new(user: @user, scope: "direct_job_title")
adapter.one_shot(workspace_path, prompt: prompt, log_sink: log_sink,
                 runner: @runner, timeout: timeout, max_turns: max_turns)

# IngestionClassifier#run_once
adapter = AgentProviders.for(@provider).new(user: @user, scope: "ingestion_classifier")
adapter.one_shot(workspace_path, prompt: prompt, log_sink: log_sink,
                 runner: RunJob.agent_runner, timeout: timeout, max_turns: max_turns)
```

## Files to update

- `app/services/agent_providers/base.rb` — add `one_shot` abstract method
- `app/services/agent_providers/claude.rb` — implement `one_shot`
- `app/services/agent_providers/codex.rb` — implement `one_shot` (extract shared Codex lifecycle)
- `app/services/direct_job_title_generator.rb` — replace case block
- `app/services/ingestion_classifier.rb` — replace case block

## Out of scope

- Changing timeout or retry behavior
- Merging `DirectJobTitleGenerator` and `IngestionClassifier` into one class
- Unifying the one-shot path with the full workflow run path (they have different lifecycle needs)
