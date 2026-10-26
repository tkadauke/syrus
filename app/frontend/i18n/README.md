# Frontend i18n maintenance

Core locale namespaces live in `locales/{en,de,la}` and must keep matching key
trees. Before adding or revising recurring product terminology, consult the
[core localization glossary](../../../docs/i18n-glossary.md). It defines the
approved German register and terms and identifies every Latin domain term that
must remain pending competent review.

Use `useT` with the owning namespace for user-visible SPA copy. Run the focused
i18n specs after catalog changes:

```sh
bundle exec rspec spec/i18n
```

The glossary is terminology policy. It does not replace the existing locale
key-parity or untranslated-source audits, and it does not authorize Latin
domain-noun normalization while review is pending.
