# Sources

A source is a named JSON object whose properties a field can draw through the HTTP API. The `sources` plugin publishes the registry as `"sources"`. `json-source` adds the record `example`:

```json
{"title":"Niimbench","sku":"NB-1"}
```

That plugin lives in `src/example_source.zig`. It calls `Sources.add` inside `apply` and `Sources.remove` from its `ctx.effect`, so removing the `json-source` fiber removes the name and both copies the registry holds.

## Two lifetimes

| Added by | Lives until | Removed by |
|---|---|---|
| A plugin's `apply` | That fiber is disposed | nothing over HTTP |
| `POST /api/sources` | The `http` fiber is disposed | `DELETE /api/sources/<name>` |

`Sources.add` copies the name and the body, so the caller keeps its own slice. `Sources.addOwned` takes them over instead, which is what the runtime path uses. `Sources.remove` hands back the entry it took out, and the caller frees it.

`POST /api/sources` takes `{"name": "...", "json": "{...}"}`. The body must parse as a JSON object, because `label.Field.key` reads one property out of a flat record. A name that is already installed at runtime is replaced, and the answer says `{"ok":true,"replaced":true}`. A name is 1 to 64 bytes with no `/`, `"`, `\`, or control byte, because `GET /api/sources` writes names into its JSON answer as they are; anything else is `bad name`. A name a plugin holds is refused with `source belongs to a plugin`, as a `DELETE` of it is.

Records installed this way are owned by a `RuntimeSources` list on the `http` plugin. `DELETE /api/sources/<name>` drops one, `GET /api/runtime-sources` lists the ones it owns, and disposing the `http` fiber drops whatever is left. A record a plugin owns is refused, so the route cannot outlive the effect that owns the record.

## Reads

`GET /api/sources` lists names. `GET /api/sources/example` returns that object.

## A field and a record

A field with a `key` draws the value of that property, and a field with only `text` draws that literal. A field with both draws the source value, because `label.resolve` prefers `key`. This is the API's own behaviour: `POST /api/render` and `POST /api/print` take `key` on a field, and a layout file can use it.

The editor does not offer it. Its rows are plain text fields, with no source chooser and no per-row key; it sends no `source` or `key`, and drops both from a loaded layout.

Another integration is another plugin with `inject: ["sources"]` that adds records in `apply` and removes them from its effect. Fetching a network service belongs in that plugin's `apply` or in the handler it registers, not in the page.
