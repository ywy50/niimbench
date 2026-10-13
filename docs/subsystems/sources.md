# Sources

A source is a named JSON object the editor can drop onto a label. The `sources` plugin publishes the registry. `json-source` adds the record `example`:

```json
{"title":"Niimbench","sku":"NB-1"}
```

`GET /api/sources` lists names. `GET /api/sources/example` returns that object. Removing the `json-source` fiber removes the name.

Another integration is another plugin with `inject: ["sources"]` that calls `Sources.add` inside `apply` and `Sources.remove` from its effect. The editor does not learn a new URL shape. Fetching a network service belongs in that plugin's `apply` or in the handler it registers, not in the page.

The page shows the fetched JSON in the "Fill from source" line. Mapping those keys onto drawn text is the next editor step; the registry is the seam for it.
