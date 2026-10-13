# Swift wire compatibility review

The version 1 Hub Network JSON contract is compatible with synthesized Swift
`Codable` when implementations use:

- `String` for RFC 3339 timestamps, identifiers, addresses, keys, and base64;
- `UInt16` for ports, `UInt32` for candidate priority, and `UInt64` for resource
  generations;
- optional properties for fields carrying JSON `omitempty` semantics; and
- a tagged policy structure (`mode`, optional `group`, optional `keys`) so its
  JSON shape matches TypeScript and Go without custom enum coding.

The companion test reads a package-local copy of canonical fixtures. Set
`HUB_NETWORK_FIXTURES` to verify another fixture directory explicitly.
