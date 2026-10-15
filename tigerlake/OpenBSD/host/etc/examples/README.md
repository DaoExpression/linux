# `host/etc/examples/`

Files here are **documentation, not live configuration**. They live in
`examples/` precisely so that nothing picks them up automatically:

* `netstart(8)` globs `/etc/hostname.*`, so a file named `hostname.wg0` would
  be applied at boot even if `wireguard-tools` is not installed, producing
  errors on every boot. Files in this directory are not named `hostname.*`.
* `rc(8)` only reads files it knows about, so an "off by default" daemon
  config cannot be enabled by accident here.

Copy a file out of `examples/` into place when you actually want it:

```sh
cp /etc/examples/wireguard-hostname.wg0 /etc/hostname.wg0
sh /etc/netstart wg0
```

| File                           | What it is                                     |
| ------------------------------ | ---------------------------------------------- |
| `wireguard-hostname.wg0`       | WireGuard alternative to `iked(8)` road warriors |
| `pf.conf.example-strict-egress`| Egress filtering variant of `pf.conf`           |
