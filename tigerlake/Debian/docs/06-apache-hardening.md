# 06 — Apache hardening (the service you are actually exposing)

Assumes `docs/02`–`docs/05` are done. Everything referenced here ships under `files/etc/apache2/`
and is installed by `scripts/harden-apache.sh`, which validates and rolls back on failure.

---

## 1. Principles

1. **A web server is a parser.** Every module is another parser reachable by strangers. Remove all
   of them you do not use; that is the difference between "hardened" and "config with nice headers".
2. **No dynamic language on the host.** No `mod_php`, no Perl/Python/Node handlers, no `mod_cgi`.
   If the application needs PHP, it runs in its own isolated instance or container (`docs/08`), never
   in this process.
3. **One security domain per process.** If you host unrelated sites, use separate instances/users
   (§7) rather than a single `www-data` with overlapping access.
4. **Fail closed and speak little.** No version banners, no directory listings, no stack traces, no
   `Server` details, generic error pages.
5. **The unit is sandboxed, not just the config.** `systemd-analyze security` should report a low
   exposure score — see §6.

## 2. Module pruning — do this first

```bash
bash scripts/harden-apache.sh --prune-modules --dry-run     # prints what will be disabled
sudo bash scripts/harden-apache.sh --prune-modules
```

The script disables (with `a2dismod`), and the justification for each:

| Module | Why it goes |
|---|---|
| `autoindex` | Directory listings are an information-disclosure primitive and a common misconfiguration fallback. |
| `negotiation` | Content negotiation is rarely wanted and adds request-parsing surface. |
| `status` | `/server-status` leaks vhosts, clients, URLs. **If** you want it, restrict to `Require ip 127.0.0.1` (§5). |
| `info` | `/server-info` dumps the entire config. No. |
| `userdir` | `~user` paths and home-directory assumptions. |
| `cgi`,`cgid` | Arbitrary process execution from the web root. The single biggest "instant RCE" footgun. |
| `imagemap` | Ancient, unnecessary parser. |
| `include` | SSI: server-side execution in HTML files. |
| `speling` | Auto-corrects URLs by scanning directories; leaks names and forces filesystem walks. |
| `dav`,`dav_fs`,`dav_lock` | WebDAV write methods. Only if you truly need them, and then in an isolated instance. |
| `proxy*`,`proxy_http`,`proxy_balancer`,`proxy_connect`,`proxy_ftp` | A misconfigured open proxy is a felony-grade foot-gun. Remove unless this IS a reverse proxy by design. |
| `actions`,`auth_digest` | Digest auth is obsolete (MD5). Basic auth over TLS on an isolated admin vhost (mTLS + password) is the floor, nothing weaker. `env` is **kept**: it is tiny and many configs legitimately need `SetEnv`. |
| `php*`,`perl`,`python`,`wsgi`,`cgi`-family | Host-side dynamic languages: forbidden by principle 2. |
| `rewrite` | **Keep** (needed for HTTP→HTTPS and for a strict 404 policy) — but every `RewriteRule` is a regex; keep it to a couple of lines you understand. |
| `ssl`,`headers`,`socache_shmcb`,`http2`,`mpm_event`,`log_config`,`mime`,`dir`,`alias`,`authz_core`,`authz_host`,`authn_core`,`auth_basic`,`setenvif`,`unixd`,`filter`,`deflate`,`reqtimeout`,`authz_core` | **Keep.** These are the load-bearing ones for a TLS server. |

```bash
# after pruning, confirm what is actually loaded
sudo apache2ctl -M | sort
sudo apache2ctl -t -D DUMP_RUN_CFG | head
```

## 3. Global config — `files/etc/apache2/apache2.conf`

Compared with Debian's stock file, the differences that matter:

```apache
ServerTokens Prod                    # 'Server: Apache' and nothing else
ServerSignature Off                  # no version in error pages
TraceEnable Off                      # TRACE/TRACK off (cross-site tracing)
HostnameLookups Off                  # no reverse DNS: no latency, no DNS traffic from Apache, no leaks
Timeout 30
KeepAlive On
MaxKeepAliveRequests 64
KeepAliveTimeout 5
LimitRequestFields 40
LimitRequestFieldSize 4096
LimitRequestLine 4096
LimitRequestBody 1048576             # 1 MiB ceiling; override per site if you accept uploads
LimitXMLRequestBody 0                # no XML bodies at all (kills XXE/Billion-Laughs at the door)
UseCanonicalName Off                 # do not trust Host: for self-referential URLs
FileETag None                        # ETags leak inode numbers on some FS; disable them
```

`sec-hardening` directives (shipped in `conf-available/security-hardening.conf`):

```apache
<Directory />
    AllowOverride None
    Options None
    Require all denied
</Directory>

<Directory /var/www/>
    AllowOverride None               # .htaccess is an attacker-writable config file; forbid it
    Options -Indexes -ExecCGI -Includes -MultiViews
    Require all granted
</Directory>

# Do not leak the filesystem layout
<LocationMatch "^\/(\.|%2e)">
    Require all denied
</LocationMatch>
RedirectMatch 404 /\..*$           # deny dotfiles and dot-dirs everywhere
```

`mime.conf` hardening: keep the default `AddType`/`AddHandler` but **remove** anything that maps a
path to a handler. The shipped file also contains the classic trap fix:

```apache
# A file called evil.php.jpg must never be treated as anything but an image
<FilesMatch "\.(php|phtml|phar|pl|py|cgi|sh|asp|jsp)$">
    Require all denied
</FilesMatch>
```

That single rule means even if an attacker lands a file in the web root, it does not *execute* — the
host has no handler for it anyway (principle 2), but defense in depth costs nothing here.

`ports.conf`:

```apache
Listen 443
# Uncomment ONLY for HTTP-01 ACME validation; DNS-01 is recommended (§4)
#Listen 80
```

## 4. TLS — TLS 1.3 only, post-quantum key exchange, ACME via DNS-01

`files/etc/apache2/conf-available/tls-hardening.conf`:

```apache
# — protocol floor and ceiling: 1.3 only —
SSLProtocol -all +TLSv1.3
# TLS 1.3 ciphersuites (only the two AEAD suites worth having)
SSLOpenSSLConfCmd Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
# Post-quantum hybrid key exchange first (OpenSSL 3.5 / trixie), then classical curve
SSLOpenSSLConfCmd Groups X25519MLKEM768:X25519:P-384:P-256
SSLOpenSSLConfCmd Curves X25519MLKEM768:X25519:P-384
SSLOpenSSLConfCmd MinProtocol TLSv1.3
SSLHonorCipherOrder off              # no-op for 1.3, kept explicit for auditors
SSLCompression off
SSLSessionTickets off                # forward secrecy without ticket-key rotation games
SSLOptions +StrictRequire
SSLInsecureRenegotiation off
SSLVerifyClient none                 # override with 'require' on admin-only vhosts (§5)
```

Why TLS 1.3 only: it removes the entire class of 1.2-era footguns (CBC/RC4/3DES, renegotiation,
weak DH groups, downgrade attacks, RSA key exchange → no forward secrecy). The cost is real: old
clients (Android < 5.0-era, Windows < 10, some embedded/Java 8 builds) cannot connect. For a public
site, verify your client population or add TLS 1.2 **with** `SSLCipherSuite ECDHE-...GCM` explicitly
listed. Do not add 1.1/1.0 — ever.

**OCSP stapling — a 2026 trap:** Let's Encrypt **discontinued its OCSP service in 2025** in favour of
CRLs. So `SSLUseStapling on` with an LE certificate now does nothing useful (no responder to staple).
Ship it as:

```apache
# Only meaningful if your CA still runs an OCSP responder.
# Let's Encrypt removed OCSP in 2025 -> stapling is a no-op for LE certs. Leave this block
# commented unless you use a CA that still staples.
#SSLUseStapling on
#SSLStaplingCache shmcb:/run/apache2/stapling(128000)
```

Certificate acquisition: **use DNS-01 ACME validation**, not HTTP-01. Reasons: it needs **no inbound
port 80**, it covers wildcards, it keeps working when your HTTP stack is down (renewal is
independent of the thing being renewed), and it removes an entire vhost/serving path from the attack
surface.

```bash
sudo apt-get install --no-install-recommends certbot
# DNS-01 needs a plugin for YOUR DNS provider, or use the manual/webhook hooks.
sudo certbot certonly --dns-<provider> -d example.com -d www.example.com \
     --key-type ecdsa --rsa-key-size 384 \
     --deploy-hook 'systemctl reload apache2'
```

Operational notes that trip people up:

- **ECDSA (`--key-type ecdsa`, P-256 default) is better here**: smaller, faster, and Apache/OpenSSL
  handle it natively. Keep an RSA certificate as a fallback only if you must support ancient clients.
- Renewal: `certbot.timer` (shipped by the package) runs twice daily. Verify with
  `systemctl list-timers certbot.timer` and `sudo certbot renew --dry-run`.
- The **`--deploy-hook` must not restart, only reload** — a failed restart at 03:00 while nobody is
  watching is how you get an outage. `reload` keeps the old process if the new config is invalid.
- Private keys live in `/etc/letsencrypt/live/<domain>/privkey.pem` (mode 0600 root). Apache's master
  process runs as root and reads them; the `www-data` children cannot. Confirm with
  `sudo -u www-data cat /etc/letsencrypt/live/*/privkey.pem` → must be **Permission denied**.
- **If your private key is high-value** (impersonation of many domains), consider moving the key
  material to a hardware token (YubiKey PIV / a TPM-backed OpenSSL provider) later. Apache supports
  `SSLCryptoDevice` with an engine/PKCS#11 provider; this is advanced and easy to get wrong, so it is
  a documented future improvement rather than part of this build.

Verify the TLS result from off-box — do not trust the config file:

```bash
sudo apache2ctl configtest
sslscan <server>:443 | head -20            # expect TLS 1.3 suites only
openssl s_client -connect <server>:443 -tls1_3 -groups X25519MLKEM768 </dev/null 2>&1 | grep -E 'group|Protocol'
openssl s_client -connect <server>:443 -tls1_2 </dev/null 2>&1 | grep -iE 'handshake failure|alert'
curl -sSI https://<server> | grep -iE 'strict-transport|server:'
```

## 5. Headers, methods, admin vhosts

`files/etc/apache2/conf-available/headers-hardening.conf`:

```apache
<IfModule mod_headers.c>
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" env=HTTPS
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "DENY"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Cross-Origin-Opener-Policy "same-origin"
    Header always set Cross-Origin-Resource-Policy "same-origin"
    Header always set Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"
    Header always set Content-Security-Policy "default-src 'self'; base-uri 'self'; frame-ancestors 'none'; object-src 'none'; form-action 'self'; upgrade-insecure-requests"
    # never let a proxy or browser cache a response containing secrets
    Header always unset X-Powered-By
    Header always unset Server
    Header edit Set-Cookie ^(.*)$ "$1; HttpOnly; Secure; SameSite=Strict"
</IfModule>

# Only the methods you serve. Everything else gets 405.
<Location />
    <LimitExcept GET HEAD POST>
        Require all denied
    </LimitExcept>
</Location>
```

Adjust the CSP to the application — a `default-src 'self'` policy will break a site that loads CDN
scripts. **Do not** add `unsafe-inline` to make it work; serve the assets yourself. This is the one
header that meaningfully reduces the impact of an XSS in your app.

Admin-only vhost pattern (bind it to the WireGuard address so it is not internet-reachable):

```apache
<VirtualHost 10.66.0.1:443>
    ServerName admin.internal
    SSLEngine on
    SSLCertificateFile      /etc/ssl/private/admin.crt
    SSLCertificateKeyFile   /etc/ssl/private/admin.key
    SSLVerifyClient require                 # mutual TLS: client cert must be signed by your CA
    SSLVerifyDepth 1
    SSLCACertificateFile /etc/ssl/private/admin-ca.crt
    <Location />
        Require ssl-verify-client
        AuthType Basic
        AuthName "restricted"
        AuthUserFile /etc/apache2/.htpasswd-admin   # 0600 root:root
        Require valid-user
    </Location>
    ErrorLog  /var/log/apache2/admin_error.log
    CustomLog /var/log/apache2/admin_access.log paranoid
</VirtualHost>
```

Two independent factors (client certificate **and** a password) in front of anything administrative.
`server-status`, if you keep `mod_status`, only here:

```apache
<Location /server-status>
    SetHandler server-status
    Require ip 127.0.0.1 10.66.0.1
</Location>
```

## 6. Sandboxing the Apache unit

`files/etc/systemd/system/apache2.service.d/99-paranoid.conf`:

```ini
[Service]
# — filesystem —
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ReadWritePaths=/var/log/apache2 /var/lib/apache2 /run/apache2 /var/cache/apache2
InaccessiblePaths=/root /home
# — kernel/namespace —
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectProc=invisible
ProcSubset=pid
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
# — syscalls/capabilities —
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete @mount @debug @cpu-emulation @swap @keyring
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_KILL
NoNewPrivileges=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0027
```

Warnings to respect, because two of these break things silently if you add the wrong module:

- `MemoryDenyWriteExecute` is **not** in the list on purpose. `mod_security3` (libmodsecurity/RE2),
  and any dynamic language, may need W^X-incompatible mappings. Add it only after testing with your
  exact module set; if you do, run `ModSecurity` rules through a request and watch for crashes.
- `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`: if you later add `mod_ldap`/DNS lookups
  handled through `AF_NETLINK`, they will fail. Watch `journalctl -u apache2` for `socket()` denials.
- Do **not** add `PrivateUsers=yes`: Apache binds low ports and must setuid to `www-data`; it will
  fail to start. If you want that isolation, listen on 8080/8443 inside the namespace and redirect
  the ports with nftables — a deliberate, documented choice, not a copy-paste.

```bash
sudo cp files/etc/systemd/system/apache2.service.d/99-paranoid.conf /etc/systemd/system/apache2.service.d/
sudo systemctl daemon-reload && sudo systemctl restart apache2
sudo systemd-analyze security apache2 | tail -20       # target: exposure < 2.0
curl -skI https://localhost/ | head -3                 # still serving?
journalctl -u apache2 -n 30 --no-pager | grep -iE 'denied|failed'
```

## 7. Isolation between sites (when you have more than one)

`www-data` shared by five sites means a bug in one reads all five. Options, cheapest first:

1. **Separate instance per security domain** — a template unit and per-instance config:
   `files/etc/systemd/system/apache2@.service`, `files/etc/apache2/instances/site1.envvars`,
   `files/etc/apache2/instances/site1.conf`. Each instance gets its **own user**
   (`adduser --system --no-create-home --shell /usr/sbin/nologin site1`), its own ports
   (`8443`, `8444`, …) and its own `ReadWritePaths` in a `%i`-aware drop-in.
2. **nftables redirect** maps public 443 to the per-site port. Because TLS SNI is inside the
   encrypted stream, a redirect cannot route by hostname — so this works cleanly only when each site
   has its own IP address (or one site per port/domain combination). Otherwise you need a
   reverse-proxy front end.
3. **Front-end Apache terminating TLS + `mod_proxy` to Unix-socket backends.** Fine, but now you
   have re-enabled `mod_proxy`, which §2 removed for good reason: a proxy bug is a serious bug. If you
   go this route, the backends must be unreachable except via the socket, and the proxy vhost needs
   `ProxyPass` to a fixed socket path with no user-controlled component (no `ProxyPass` with
   unvalidated `$1` from a Regex — that is SSRF).
4. **Full container/VM per site** — `docs/08`. Most isolation, most overhead. Correct answer when the
   tenants do not trust each other.

For a single-purpose server (the stated goal), **one instance, one site, `www-data`** is the right
answer. Do not build §7 machinery "just in case".

## 8. mod_security3 + OWASP CRS

```apache
# files/etc/apache2/mods-available/security2.conf  (installed as security2.conf)
<IfModule security2_module>
    SecRuleEngine On                       # DetectionOnly is for tuning only — the artefact uses On
    SecRequestBodyAccess On
    SecResponseBodyAccess Off              # response inspection is expensive and rarely pays off here
    SecRequestBodyLimit 131072             # 128 KiB, matches LimitRequestBody intent
    SecRequestBodyNoFilesLimit 131072
    SecRequestBodyInMemoryLimit 131072
    SecRequestBodyLimitAction Reject
    SecPcreMatchLimit 100000
    SecPcreMatchLimitRecursion 100000
    SecDebugLogLevel 0                     # never log request bodies at debug on a public box
    SecAuditEngine RelevantOnly
    SecAuditLogRelevantStatus "^(?:5|4(?!04))"
    SecAuditLogParts ABIFHZ
    SecAuditLogType Serial
    SecAuditLog /var/log/apache2/modsec_audit.log
    SecDataDir /var/cache/apache2/mod_security2
    SecTmpDir /var/cache/apache2/mod_security2
    SecUploadKeepFiles Off
    SecUploadDir /var/cache/apache2/mod_security2
    SecDefaultAction "phase:1,log,auditlog,deny,status:403"
    SecDefaultAction "phase:2,log,auditlog,deny,status:403"
    IncludeOptional /etc/modsecurity/modsecurity.conf
    IncludeOptional /usr/share/modsecurity-crs/*.load
    IncludeOptional /etc/modsecurity/crs/paranoid-crs.conf
</IfModule>
```

`files/etc/modsecurity/crs/paranoid-crs.conf` sets the CRS posture:

```apache
SecAction "id:900000,phase:1,nolog,pass,t:none,setvar:tx.blocking_paranoia_level=2"
SecAction "id:900001,phase:1,nolog,pass,t:none,setvar:tx.detection_paranoia_level=2"
SecAction "id:900110,phase:1,nolog,pass,t:none,\
  setvar:tx.inbound_anomaly_score_threshold=15,\
  setvar:tx.outbound_anomaly_score_threshold=8"
SecAction "id:900130,phase:1,nolog,pass,t:none,setvar:tx.enforce_bodyproc_urlencoded=1"
SecAction "id:900990,phase:1,nolog,pass,t:none,setvar:tx.crs_setup_version=400"
```

Tuning procedure (this is the part that takes an afternoon, not five minutes):

1. Start at PL1 with `SecRuleEngine DetectionOnly` for 24–48 h and real traffic.
2. Read `/var/log/apache2/modsec_audit.log`, classify every hit as *true positive* or *app bug*.
3. Add **narrow** exclusions per rule id and per URI path in `paranoid-crs.conf` — never disable a
   whole rule category, and never `ctl:ruleRemoveTargetById` across the whole vhost.
4. Raise to PL2, switch to `On`, then re-watch. Repeatedly hitting the anomaly threshold on normal
   traffic means you tuned wrong, not that the traffic is malicious.
5. `SecAuditLog` **must** be rotated and must not be world-readable: `files/etc/logrotate.d/modsec`
   ships a rotation block with `create 0640 root adm`.

Honest limitation: CRS is a signature set. It stops commodity scanners and lazy exploitation; it will
not stop a determined attacker with a novel bug in your application. Its real value here is that it
raises the cost of automation and gives you an audit trail of attempts.

## 9. Logging and log integrity

```apache
LogFormat "%v %{X-Forwarded-For}i %h %l %u %t \"%r\" %>s %b %D %{SSL_PROTOCOL}x %{SSL_CIPHER}x \"%{User-Agent}i\" %{Referer}i" paranoid
LogLevel warn
# piped to journald at Tier 2 so events land in a remote-shippable, sealed store
CustomLog "|/usr/bin/logger -t apache_access -p local6.info" paranoid
ErrorLog  "|/usr/bin/logger -t apache_error  -p local6.err"
```

- Everything lands in the journal, which is already configured (`docs/04` §10) to be persistent,
  size-limited and **sealed**; `systemd-journal-upload` can ship it off-host over TLS. That is a far
  better story than Apache writing files nobody reads.
- If you prefer files, keep `files/etc/logrotate.d/apache2` (shipped) and remember `/var/log` is
  mounted `noexec` — a webshell cannot be dropped there.
- Never log request bodies, `Authorization` headers, or cookies. `mod_security`'s audit log parts must
  stay `ABIFHZ` (no `C`/`E` = no request body content) exactly as shipped.

## 10. Verification

```bash
sudo apache2ctl configtest                        # Syntax OK (a warning about a missing FQDN is fine)
sudo apache2ctl -M | sort                         # only the modules you decided to keep
sudo apache2ctl -S                                # vhost map: nothing you did not intend
sudo systemd-analyze security apache2 | tail -3
sudo ss -tulpn | grep apache                      # :443 (and :80 only if HTTP-01)
curl -sI https://<server>/ | grep -iE 'server|strict-transport|x-content-type|content-security'
curl -sI https://<server>/../etc/passwd | head -1 # expect 400/404, never 200
curl -s https://<server>/%2e%2e/ | head -1        # expect 404
bash scripts/verify-hardening.sh --section apache
sudo certbot renew --dry-run
```

Then re-run the AIDE baseline (`docs/04` §8) — the web server config is now final and should be
part of the integrity baseline.
