# scripts/Makefile - convenience wrapper for the runbook in README.md
#
#   make help        list targets
#   make docs-html   rebuild the single-file HTML reference (dark theme, offline)
#   make lint        bash -n every script (does not need root)
#   make dry-run     show exactly what the installer would change (Tier 2)
#   make install     apply everything (Tier 2)          [needs root]
#   make apache      prune Apache modules + install hardened config + reload
#   make verify      run the read-only verification (exit 1 on FAIL)
#   make tree        show the artefact tree that gets installed
#
# Override the tier:  make install TIER=3
# Run from the repository root:  make -f scripts/Makefile install

SHELL     := /bin/bash
REPO      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
TIER      ?= 2
SCRIPTS   := $(REPO)/scripts
ADMIN     ?= admin

.PHONY: help lint dry-run install apache verify tree preseed-check docs-html docs-html-verify

help:
	@sed -n '2,14p' $(SCRIPTS)/Makefile | sed 's/^# \{0,1\}//'

# Offline, self-contained reference page: every document plus every artefact with annotations.
docs-html:
	@python3 $(REPO)/tools/build-docs-html.py -o $(REPO)/hardened-debian-apache.html

# The build is deterministic, so a rebuild that changes the file means the committed page is stale.
docs-html-verify:
	@tmp=$$(mktemp); python3 $(REPO)/tools/build-docs-html.py -o "$$tmp" >/dev/null; \
	if cmp -s "$$tmp" $(REPO)/hardened-debian-apache.html; then \
		echo "ok   hardened-debian-apache.html is in sync with docs/ and files/"; rm -f "$$tmp"; \
	else \
		echo "STALE hardened-debian-apache.html - run: make -f scripts/Makefile docs-html"; rm -f "$$tmp"; exit 1; \
	fi

lint:
	@echo "== bash syntax check =="
	@for f in $(SCRIPTS)/*.sh; do \
		if bash -n "$$f"; then echo "  ok   $$f"; else echo "  FAIL $$f"; exit 1; fi; \
	done
	@echo "== shellcheck (if installed) =="
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning $(SCRIPTS)/*.sh && echo "  ok   shellcheck"; \
	else echo "  skip shellcheck not installed"; fi
	@echo "== Makefile parse =="
	@$(MAKE) -f $(SCRIPTS)/Makefile -n help >/dev/null && echo "  ok   Makefile"

dry-run:
	@sudo bash $(SCRIPTS)/install-hardening.sh --dry-run --tier $(TIER) --admin-user $(ADMIN)

install:
	@sudo bash $(SCRIPTS)/install-hardening.sh --tier $(TIER) --admin-user $(ADMIN)

apache:
	@sudo bash $(SCRIPTS)/harden-apache.sh

verify:
	@sudo bash $(SCRIPTS)/verify-hardening.sh --tier $(TIER)

tree:
	@echo "== artefacts installed from files/ (excluding *.example) =="
	@cd $(REPO)/files && find ./etc ./usr -type f ! -name '*.example' | sed 's|^\./|  /|' | sort
	@echo
	@echo "== reference-only files (never installed automatically) =="
	@cd $(REPO)/files && find . -type f -name '*.example' | sed 's|^\./|  /|' | sort
	@echo
	@echo "== documentation-only trees (not copied by the installer) =="
	@cd $(REPO)/files && find ./keys -type f 2>/dev/null | sed 's|^\./|  files/|' | sort

preseed-check:
	@echo "== preseed sanity (structure only; ALWAYS test in a VM first) =="
	@test -f $(REPO)/preseed/paranoid-preseed.cfg || { echo "  FAIL preseed missing"; exit 1; }
	@grep -q 'partman-auto/method string crypto' $(REPO)/preseed/paranoid-preseed.cfg && echo "  ok   encrypted partitioning requested"
	@grep -q 'partman-auto/expert_recipe' $(REPO)/preseed/paranoid-preseed.cfg && echo "  ok   expert recipe present"
	@grep -q 'pkgsel/install-recommends boolean false' $(REPO)/preseed/paranoid-preseed.cfg && echo "  ok   recommends disabled"
	@grep -Eq 'tasksel/tasks.*none|tasksel/first' $(REPO)/preseed/paranoid-preseed.cfg && echo "  ok   no desktop task"
	@echo "  reminder: preseed files are NOT a substitute for reading docs/02"
