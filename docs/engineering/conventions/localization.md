# Localization

Use these rules for user-visible frontend and backend copy.

- **Frontend i18n** — all user-visible strings in the SPA use i18next. Use the
  `useT` hook (`app/frontend/hooks/useT.ts`, a re-export of `useTranslation`) and
  pick the right namespace (`common`, `nav`, `jobs`, `epics`, `dashboard`, `chat`,
  `settings`, `admin`). Locale files live under
  `app/frontend/i18n/locales/{en,de,la}/`. When adding new strings, add them to
  all three locales. Backend: `User#locale` drives `I18n.locale` per request via
  `ApplicationController#switch_locale`; `User::LOCALES` is the source of truth
  for valid values.
