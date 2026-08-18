# Translations — `Fractal.translations`

Pulls approved translations from Fractal at runtime and registers them with Godot's `TranslationServer`. Bundled `.translation` files remain the offline fallback. Disabled subsystem = silent no-op.

## API

```gdscript
# Sync all locales listed in `config.translations_locales`.
# Falls back to TranslationServer.get_loaded_locales() if the list is empty.
Fractal.translations.sync() -> void

# Sync a single locale.
Fractal.translations.sync_locale(locale: String) -> void

# Switch the active locale (also fires `language_changed` and propagates
# NOTIFICATION_TRANSLATION_CHANGED so existing UI re-translates).
Fractal.translations.set_locale(locale: String) -> void

Fractal.translations.get_locale() -> String
Fractal.translations.available_locales() -> PackedStringArray  # locales registered via this loader

Fractal.translations.is_enabled() -> bool
```

### Signals

```gdscript
signal sync_started(locale: String)
signal sync_succeeded(locale: String, message_count: int)
signal sync_failed(locale: String, error: String)
signal language_changed(locale: String)
```

## Sync flow per locale

1. Read the stored ETag from `user://fractal/translations_etags.cfg`.
2. Issue `GET {api_url}/api/v1/translations/sync?locale={locale}` with `X-API-Key` and (if present) `If-None-Match: <stored_etag>`. The API key alone identifies your project — no `project_id` needed.
3. **`200 OK`**: parse the response, save translations to `user://fractal/translations/{locale}.json`, save the new ETag, and register a `Translation` resource with `TranslationServer.add_translation(...)`. `sync_succeeded` fires.
4. **`304 Not Modified`**: load `user://fractal/translations/{locale}.json` from cache and apply it. `sync_succeeded` fires.
5. **HTTP error or no network**: load the cached version (if any) and apply it. `sync_failed` fires. Bundled `.translation` files continue to resolve through `TranslationServer`'s lookup chain.

If the cache is corrupt (invalid JSON), the loader deletes it and treats this as an empty cache — the next successful sync repopulates it.

## Endpoint shape

The Rails endpoint at `GET /api/v1/translations/sync?locale=es` returns:

```json
{
  "locale": "es",
  "etag": "sha1...",
  "translations": {"ui.start": "Comenzar", "ui.quit": "Salir"}
}
```

Only translations with `status: "approved"` are included. The ETag is a SHA1 of `(translation_id, updated_at)` pairs — it changes whenever any approved translation in the locale is updated.

## Composing with bundled translations

`TranslationServer.add_translation(...)` adds Fractal's translations as additional sources rather than replacing existing ones. This means:

- If you ship a `strings.fr.translation` file, those strings remain available even when offline.
- If Fractal has a string for the same key, Fractal's version wins (most recently registered translation is consulted first for matching locale).
- If Fractal has a key your bundled file doesn't, it just works.
- If Fractal lacks a key your bundled file has, the bundled value is used (no fallback gymnastics needed).

The loader stores a reference to each Translation it registers so re-syncing the same locale removes the stale version before applying the new one — preventing "stale key from a previous sync" leaks.

## Recommended config

```gdscript
# Production: sync once at launch, re-sync every 6 hours.
Fractal.configure({
    "translations_enabled": true,
    "translations_locales": PackedStringArray(["en", "es", "fr", "de", "ja"]),
    "translations_sync_on_startup": true,
    "translations_sync_interval_hours": 6.0,
})

# Development: sync only when you ask (e.g., a "Sync now" debug button).
Fractal.configure({
    "translations_enabled": true,
    "translations_sync_on_startup": false,
})
```

## Manual seed (no editor CSV import required)

If you don't want to depend on Godot's CSV importer (e.g., for headless smoke runs), you can seed `TranslationServer` directly from a CSV. The test_game's `analytics_glue.gd` does this — see [`test_game/scripts/analytics_glue.gd`](../test_game/scripts/analytics_glue.gd) for a 30-line reference implementation.
