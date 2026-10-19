# Trace

The `trace` plugin keeps a running log of what the process and the page have been asked to do, in memory, readable while it runs. It is a diagnostic: when a label comes out wrong, or a button does nothing, the useful question is *what did each side actually do* — and that answer is not in a stack trace. The plugin publishes a `Trace` service that other plugins write to. The `http` plugin serves it at two routes, one that reads it back and one the page writes to.

The printer is on the other end of a wire and the editor is in another process, so a single line has to carry enough to place it: the plugin records a relative time, who said it, how bad it is, and the message.

## Routes

| Method | Path | What it does |
|---|---|---|
| `GET` | `/api/trace` | The whole log, oldest first, as plain text |
| `GET` | `/api/trace?clear=1` | Empties the log first, leaving one `cleared` line |
| `POST` | `/api/trace` | Adds a line from the page |

Both routes need the session token like every other route. The body of a `POST` is `{"level": "...", "source": "...", "message": "..."}`; every field is optional and the defaults are `info`, `page`, and an empty message. `level` is `info`, `warn` or `error`.

A read looks like this:

```
      0ms info    trace     opened
   3521ms info    roll      01222281 -> 12x40 mm 96x320 dots from the catalogue
   3526ms info    page      view: vertical · roll 96×320 · view 320×96 · canvas 320×96
   9377ms info    print     96x320 dots, 304 rows printed, 1 field(s), 1 copy, density 3, bluetooth AA:BB:CC:DD:EE:FF
   9377ms error   print     bluetooth AA:BB:CC:DD:EE:FF model=d110 failed: MethodFailed
```

The first column is milliseconds since the log opened, so `3521` and `3526` are the same instant in different processes, and what came first is never in doubt.

## What is recorded

| Source | When |
|---|---|
| `trace` | The plugin starting, and a clear |
| `server` | `quit from the page` when the menu stops it |
| `scan` | A scan whose finder failed, and why |
| `roll` | A barcode and the size it resolved to, or why the read failed |
| `print` | What was composed, where each field was, what the printer was, and how it ended |
| `clock` | What time a printer's clock was set to, and what it answered |
| `printer` | The link opening, the D-series protocol probe (`protocol N`, or why it failed), what each print command answered, how many rows went in how many packets, every `PrintStatus` reading as raw bytes, a head polled by `PrintEnd` instead, the `PrintEnd` try that closed the job, a heartbeat that failed, and at `warn` a copy the job did not ask for (`page N done and another copy started`) |
| `page` | The boot steps, a scan's result, the view the page is showing, a picked printer, the position and angle of every field box when that changes, every step of a drag, a picture imported and sent, and any script error |

The page reports its own errors — `window.onerror` and `unhandledrejection` both post a line — so a broken editor shows up in the log instead of only in a console that is gone by the time anyone asks. It also posts its view state whenever that changes, which is the number worth having when the preview and the printer disagree.

To add a line from the server, look the service up and call it. `tracer` in `src/server.zig` does the lookup on every call, so a context without the plugin records nothing:

```zig
if (tracer(service)) |t| t.info("roll", "{s} -> {d} dots", .{ barcode, dots });
```

`warn` and `failure` are the other levels.

## Lifetime and size

The plugin owns nothing but a fixed ring of `Trace.capacity` entries and a buffer per entry, so it cannot grow while the process runs and a page that reports in a loop cannot exhaust memory. The oldest entries are overwritten; `?clear=1` bounds a run explicitly. The service is published with `ctx.set` and dropped with the fiber's effect, like every other plugin's.

The plugin is optional. A context that mounts only `http` serves every other route and records nothing, because each call looks the service up as it goes; both trace routes answer `404` with `no trace plugin`.

## Reading it next to a report

At startup the server writes its URL, token included, to `.niimbench.token` in its working directory. The file is readable only by its owner and is replaced on every start. `make trace` reads it and prints the running server's log, so neither you nor an agent has to copy the token from the terminal:

```sh
make trace
```

`tools/trace.sh` wraps the two calls a bug report needs: it clears the log, runs whatever command you give it, and prints the lines that appeared, so the output is only about that command. The command gets `NIIMBENCH_URL` and `NIIMBENCH_TOKEN` in its environment. Against the server running from this folder, both come from the token file; this one prints to a USB path that does not exist, which needs no printer and still records the job and its failure:

```sh
url=$(cat .niimbench.token)
tools/trace.sh --url "${url%%/?token=*}" --token "${url##*token=}" -- sh -c 'curl -s -H "content-type: application/json" -d "{\"width\":96,\"height\":96,\"fields\":[{\"text\":\"A\"}],\"model\":\"d110\",\"conn\":\"usb\",\"addr\":\"/nonexistent\"}" "$NIIMBENCH_URL/api/print?token=$NIIMBENCH_TOKEN"'
```

The log is text on purpose. It reads with `curl`, pastes into a report, and diffs between two runs without a viewer.

## The protocol is checked, not remembered

The page declares the steps a boot must record in `tracedSteps`. **A step declares itself by being traced**: `traceStep("...")` writes the line and adds its first two words to `tracedSteps`, so a step cannot run without joining the protocol, and there is no second list to keep in step by hand.

| Check | Runs | Catches |
|---|---|---|
| `server.test.the editor records every step of its protocol` | `zig build test`, `make test` | A `tracedSteps` list that has stopped filling itself, a page with no `traceStep`, and the server's own `opened` line leaving the protocol |
| `tools/trace-protocol.test.js` | `make protocol-test`, `make test` | A step the page's source declares that neither the page nor the server records, and a boot phase that records no step inside its own code |
| `tools/trace-test.js` | `make trace-test`, `make test` | A declared step with no line in the trace, and it prints the whole trace |

The first is the one that cannot be avoided: it is part of the project's own test command and it reads the embedded page. New behaviour that traces itself with `traceStep` is therefore enforced on the next `make test` by construction — nothing depends on reading this page or remembering a rule. A line written with a bare `traceLine("info", ...)` instead is deliberately *not* part of the protocol, so an informational line can be added without becoming a build requirement; use `traceStep` when the harness must insist on the step.

The image import is the case that motivated this. It had no trace line at all, so when an uploaded picture failed to appear there was nothing in the record to read: the page looked as though it had done nothing. It now records `image: import` with the picture's size and where it landed, and `image: sent` with the encoded length and whether the preview drew — which is what separated "never drawn" from "drawn and then rejected by the server".

## Tests

`zig build test` covers the ring: the newest entries are kept, they read back oldest first, and a message too long for its line is clipped rather than dropped. A server test mounts the plugin, fails a print, and checks that the failure and the page's own line both reach `GET /api/trace`, that order is oldest first, and that a clear empties the log. The inventory is [../testing.md](../testing.md).
