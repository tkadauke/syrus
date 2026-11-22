# Personal Calendar adapters

The experimental, default-disabled Personal Calendar plugin is distinct from the
operations Calendar plugin. It owns `personal_calendar_list_events` and
`personal_calendar_get_event`. Adapter plugins implement the provisional keyed
`personal_calendar` family capabilities `list_events` and `get_event`.

Adapters receive `PersonalCalendar::Context`, containing the selected account, a
short-lived broker access object, and normalized arguments. They return hashes and
must never return or persist token material. The concept layer marks results
`external_untrusted`, strips markup, and writes large descriptions and all attachments
to workspace files. `PersonalCalendar::FakeAdapter.events` supports network-free
adapter and tool contract tests.
