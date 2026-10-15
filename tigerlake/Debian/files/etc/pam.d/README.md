# Wiring pam_faillock and pwquality into Debian's PAM stack

Debian manages `common-auth`, `common-account`, and `common-password` through `pam-auth-update`.
**Do not hand-edit those files** — the changes will be overwritten by the next `libpam-*` upgrade.
Instead register the modules with `pam-auth-update` and then enable them.

## 1. faillock (account lockout after failures)

Create `/usr/share/pam-configs/paranoid-faillock`:

```
Name: Paranoid lockout policy (pam_faillock)
Default: yes
Priority: 300
Auth-Type: Primary
Auth:
	[default=die]	pam_faillock.so authfail
	auth-sufficient	pam_faillock.so authsucc
Account-Type: Primary
Account:
	required	pam_faillock.so
```

Then:

```bash
sudo cp files/etc/security/faillock.conf /etc/security/faillock.conf
sudo pam-auth-update --enable paranoid-faillock
sudo grep -n faillock /etc/pam.d/common-auth /etc/pam.d/common-account   # confirm the wiring
sudo faillock --user admin        # inspect the counter; --reset clears it
```

Notes that matter on a real machine:

- `pam_faillock` counts failures from `sudo`, `login`, and `su`. It is the console/sudo brute-force
  control; SSH passwords are already disabled entirely (`docs/04` §2), so there is nothing to brute
  force over the network.
- **Keep a console recovery path in mind.** `docs/04` sets `root_unlock_time=60` explicitly so a
  lockout of root clears quickly. The admin account clears after `unlock_time=900`.
- If you lock yourself out: boot the rescue ISO (`docs/03` §4 recovery), mount the encrypted root, and
  remove the `paranoid-faillock` entry from `/etc/pam.d/common-auth`/`common-account` offline.

## 2. pwquality (password policy)

The Debian `libpam-pwquality` package already ships a `pam-auth-update` profile that reads
`/etc/security/pwquality.conf` (and `pwquality.conf.d/*.conf`):

```bash
sudo apt-get install --no-install-recommends libpam-pwquality
sudo cp files/etc/security/pwquality.conf.d/99-paranoid.conf /etc/security/pwquality.conf.d/
sudo pam-auth-update --enable pwquality
# test without changing a real password:
python3 -c "import ctypes;l=ctypes.CDLL('libpwquality.so.1');print(l.pwquality_check('aaaaaaaaaaaaaaa'))" 2>/dev/null || \
  echo "check rules are applied with: sudo passwd admin  (and then abort with Ctrl-C)"
```

## 3. Verify the whole stack

```bash
sudo pam-auth-update --package        # shows the active module set
sudo faillock --user admin
sudo pwck ; sudo grpck                 # account/group integrity
sudo grep -c 'pam_unix\|pam_faillock' /etc/pam.d/common-auth
# end-to-end: from a console, fail the password 5 times and confirm the lockout message,
# then clear it with:  sudo faillock --user admin --reset
```
