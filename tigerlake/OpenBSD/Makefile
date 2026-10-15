# Makefile — OpenBSD lab configuration tree
#
# Everything here is a thin wrapper around scripts/ so that the sequence of
# operations is discoverable without reading this repository's prose.  Nothing
# is destructive; nothing here talks to a host it was not given.
#
# Typical first run:
#   make lint
#   make deploy-host GW=gw.lab.example.org
#   make sets       GW=gw.lab.example.org
#   make provision  GW=gw.lab.example.org VM=bastion
#
# Variables (override on the command line):
#   GW    the gateway, as user@host or host         (required for remote targets)
#   VM    a guest name: bastion dns db storage mon web mail

GW   ?= gw.lab.example.org
VM   ?=
ALL_VMS = bastion dns db storage mon web mail

.PHONY: help lint check shellcheck deploy-host deploy-guest deploy-all sets provision finish wipe validate

help:
	@echo "make lint                     offline checks on the whole tree"
	@echo "make check      GW=<host>     on the gateway: pfctl -nf, sshd -t, ..."
	@echo "make deploy-host GW=<host>    push host/ (and the scripts) to the gateway"
	@echo "make deploy-guest GW=<host> VM=<guest>   push common/ then vms/<guest>/"
	@echo "make deploy-all  GW=<host>    every guest, one after another"
	@echo "make sets        GW=<host>    fetch OpenBSD sets onto the gateway"
	@echo "make provision   GW=<host> VM=<guest>    create the disk, autoinstall"
	@echo "make finish      GW=<host> VM=<guest>    stop the install VM, print next steps"
	@echo "make wipe        GW=<host> VM=<guest>    delete a guest's disk (asks first)"
	@echo "make validate                 syntax-check the shell scripts here"

# ---------------------------------------------------------------- local checks
lint:
	@scripts/lint-config.sh

# NOTE: scripts/ mixes names with and without a .sh suffix (the OpenBSD
# convention for /usr/local/sbin is no suffix), so the loop matches everything.
validate:
	@for s in scripts/* host/etc/rc.local vms/*/etc/rc.local; do \
		[ -f "$$s" ] || continue; \
		sh -n "$$s" && echo "ok   $$s" || echo "FAIL $$s"; \
	done

shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed"; exit 0; }
	@for s in scripts/*; do shellcheck -s sh "$$s" || true; done

# ---------------------------------------------------------------- remote checks
# The real validators only exist on an OpenBSD host, so this is the one target
# that must reach the gateway.  It changes nothing.
check:
	@echo "== validating on $(GW) =="
	@ssh $(GW) 'set -e; \
		doas pfctl -nf /etc/pf.conf && echo "ok  pf.conf"; \
		doas sshd -t && echo "ok  sshd_config"; \
		doas httpd -n && echo "ok  httpd.conf"; \
		doas smtpd -n && echo "ok  smtpd.conf"; \
		doas nsd-checkconf /etc/nsd.conf && echo "ok  nsd.conf"; \
		doas unwind -n && echo "ok  unwind.conf"; \
		doas ntpd -n && echo "ok  ntpd.conf"; \
		doas iked -n && echo "ok  iked.conf"; \
		doas relayd -n && echo "ok  relayd.conf"; \
		doas vmctl reload && echo "ok  vm.conf"; \
		doas dhcpd -n vlan20 vlan30 veb2 && echo "ok  dhcpd.conf"'
	@echo "== zone files =="
	@ssh $(GW) 'for z in /var/nsd/zones/*.zone; do \
		doas nsd-checkzone "$$(basename $$z .zone)" "$$z" || exit 1; \
	done && echo "ok  zones"'

# ---------------------------------------------------------------- deployment
deploy-host:
	@scripts/deploy.sh host $(GW)

deploy-guest:
	@test -n "$(VM)" || { echo "set VM=<guest>"; exit 2; }
	@scripts/deploy.sh common $(GW) >/dev/null 2>&1 || true
	@scripts/deploy.sh $(VM) $(GW)

deploy-all:
	@for v in $(ALL_VMS); do \
		echo "=== $$v ==="; \
		$(MAKE) --no-print-directory deploy-guest GW=$(GW) VM=$$v || exit 1; \
	done

# ---------------------------------------------------------------- provisioning
sets:
	@ssh $(GW) 'doas /usr/local/sbin/fetch-sets.sh'

provision:
	@test -n "$(VM)" || { echo "set VM=<guest>"; exit 2; }
	@scripts/deploy.sh host $(GW)
	@ssh $(GW) "doas /usr/local/sbin/provision-vm.sh $(VM)"

finish:
	@test -n "$(VM)" || { echo "set VM=<guest>"; exit 2; }
	@ssh $(GW) "doas /usr/local/sbin/provision-vm.sh -f $(VM)"

wipe:
	@test -n "$(VM)" || { echo "set VM=<guest>"; exit 2; }
	@ssh -t $(GW) "doas /usr/local/sbin/provision-vm.sh -w $(VM)"
