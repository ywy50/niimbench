# Glossary

**Context.** The service map, listener list, and fiber list for one process.

**Plugin.** A named `apply` function plus the service keys it requires.

**Fiber.** One mount of a plugin. Disposing it runs that mount's inverses.

**Service.** A pointer published under a string key, for example `"printer"` or `"http"`.

**Effect.** A registration paired with a function that undoes it.

**Coeffect.** A service key in `inject`. The fiber applies only while every key is present.

**Source.** A named JSON record the editor can request. `json-source` publishes `"example"`.

**Transport.** An open USB serial port or RFCOMM socket with `read`, `write`, and `close`.

**Token.** 16 random bytes, printed as hex, required on every HTTP request for that process.
