# Input Sources

Input sources are plugin-provided STI classes under `InputSource`. A repository
can have one record per source class, with credentials stored encrypted on the
source and operator-editable settings stored in `config`.

Bundled source plugins:

- `github_source` registers `InputSources::Github`
- `linear_source` registers `InputSources::Linear`

Plugins register source providers at boot:

```ruby
Syrus::PluginRegistry.register(
  name: "github_source",
  version: SyrusGithubSource::VERSION,
  provides: {
    input_source:            InputSources::Github,
    source_control_provider: SourceControl::GithubOperations
  }
)
```

Repository settings enumerate available types through
`Syrus::PluginRegistry.providers_for(:input_source)`. Each provider's
`config_schema` defines the dynamic settings fields and identifies whether a
field is saved to `config` or encrypted `credentials`.

The STI `type` column stores the class name, for example
`InputSources::Github`. Moving a source implementation into a bundled plugin
does not change existing rows as long as the class name remains the same and
the plugin gem is loaded.

Input sources are not the same as source-control providers. Input sources poll
or ingest work. Source-control providers own git-host behavior such as branch,
PR, and merge operations for repositories they support. GitHub currently
provides both capabilities from the same bundled plugin.
