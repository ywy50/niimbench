# HTTP

The `http` plugin injects `printer`, `transports`, and `sources`. Its `apply` creates `HttpService`, publishes it as `"http"`, and registers `/api/health`, `/api/ports`, `/api/sources`, and `/api/print`.

The `editor` plugin injects `http` and registers `GET /`. Disposing that fiber removes the route. The page bytes live in `src/editor.html` and are embedded.

## Session

The listen address is `127.0.0.1` and the port comes from `ctx.http_port` (`0` asks the kernel for a free port). Startup writes one line to stdout:

```text
http://127.0.0.1:<port>/?token=<32 hex chars>
```

Pass `--no-open` to skip `xdg-open`. The token is generated with `getrandom` for that process only.

## Print body

`POST /api/print` takes JSON:

```json
{
  "width": 8,
  "height": 1,
  "density": 3,
  "model": "b21",
  "conn": "usb",
  "addr": "/dev/ttyACM0",
  "rotate": 0,
  "pixels_b64": "<base64 grayscale>"
}
```

`pixels_b64` is raw grayscale, one byte per pixel, not a PNG. The editor rotates on the canvas and sends `rotate: 0`. The CLI rotates with `--rotate` before the same `submit` call.

A failed job returns `{"error":"<ErrorName>"}` with status 400. After a successful job the context emits `print/done`.
