# ODP SBSA Build file
#
# ## License
#
# Copyright (c) Microsoft Corporation.
#
# SPDX-License-Identifier: Apache-2.0

include Common.mk

# ------------------------------------------------------------
# Default target
# ------------------------------------------------------------
all: secure-services uefi e2e-tests

# ------------------------------------------------------------
# Build Secure Services
# ------------------------------------------------------------
secure-services:
	$(MAKE) -C mod/secure-services all

# Build secure services with test features and coverage profile (for e2e tests)
secure-services-test:
	$(MAKE) -C mod/secure-services all CARGO_FEATURES=test-bypass-locality-check CARGO_PROFILE=coverage

# ------------------------------------------------------------
# Build UEFI with EC support by default
# Depends on mod-secure-services (mod-uefi consumes mod-secure-services artifacts)
# ------------------------------------------------------------
uefi: secure-services
	$(MAKE) -C mod/uefi patina-qemu-ec

# ------------------------------------------------------------
# Run QEMU with the built UEFI firmware
# ------------------------------------------------------------
run: secure-services uefi
	qemu-system-aarch64 \
		$(QEMU_COMMON_ARGS) \
		-drive if=pflash,format=raw,unit=0,file=$(BIOS_FV_DIR)/SECURE_FLASH0.fd \
		-drive if=pflash,format=raw,unit=1,file=$(BIOS_FV_DIR)/QEMU_EFI.fd,readonly=on \
		-serial mon:stdio \
		$(EC_SERIAL_FLAGS) \
		-display vnc=:1

run-in-devcontainer: secure-services uefi
	$(DOCKER_COMMAND_PREFIX) bash -lc "make run"

# ------------------------------------------------------------
# EC (embedded controller) firmware
# ------------------------------------------------------------
# The EC firmware is a bare-metal RISC-V binary that runs in its own QEMU
# instance. It exposes its UART over $(EC_SERIAL_SOCK); the SBSA QEMU attaches
# a second serial to that socket (see EC_SERIAL_FLAGS in Common.mk).
EC_DIR := mod/ec/platform/dev-qemu
EC_ELF := $(EC_DIR)/target/riscv32imac-unknown-none-elf/release/dev-qemu

# QEMU command that boots the EC firmware and serves the UART socket. defmt
# logs are routed over semihosting (target=native), kept separate from the
# UART protocol carried on the socket.
EC_QEMU_CMD := qemu-system-riscv32 -machine virt -bios none -display none -monitor none \
	-semihosting-config enable=on,target=native \
	-chardev socket,id=ec0,path=$(EC_SERIAL_SOCK),server=on,wait=off -serial chardev:ec0 \
	-kernel $(EC_ELF)

# Decodes the EC's defmt log stream (delivered over semihosting) into readable
# text using the firmware ELF's symbol table.
EC_DEFMT := defmt-print -e $(EC_ELF)

# Build the EC firmware.
ec:
	cd $(EC_DIR) && cargo build --release --locked

# Run the EC firmware in the foreground with decoded defmt logs
# (serves $(EC_SERIAL_SOCK)).
run_ec: ec
	@rm -f $(EC_SERIAL_SOCK)
	$(EC_QEMU_CMD) | $(EC_DEFMT)

# ------------------------------------------------------------
# One-shot demo: boot the OS and the EC, linked over the serial socket
# ------------------------------------------------------------
# The OS QEMU runs in the background (console -> /tmp/qemu-os.log, GUI on
# VNC :1 / port 5901); the EC firmware runs in the foreground so its decoded
# defmt logs are what you see in the terminal. The OS QEMU is stopped
# automatically when the EC exits (Ctrl-C). Start order doesn't matter: the OS
# side reconnects to the EC serial socket until the EC comes up.
demo: uefi ec
	@rm -f $(EC_SERIAL_SOCK)
	@echo "=== Booting OS QEMU in background (console -> /tmp/qemu-os.log, VNC :1 / port 5901) ==="
	@setsid $(MAKE) -C postbuild/os run </dev/null >/tmp/qemu-os.log 2>&1 & \
	os_pid=$$!; \
	trap 'echo "=== Stopping OS QEMU (pgid $$os_pid) ==="; kill -- -$$os_pid 2>/dev/null' EXIT INT TERM; \
	echo "=== EC firmware logs (decoded defmt) -- Ctrl-C to stop ==="; \
	$(EC_QEMU_CMD) | $(EC_DEFMT)

# ------------------------------------------------------------
# Run E2E tests against the secure partition
# ------------------------------------------------------------
# Build secure-services-test first, then uefi (skipping its normal
# secure-services dependency to avoid overwriting the test binary).
e2e-test: secure-services-test
	$(MAKE) -C mod/uefi patina-qemu-ec
	$(MAKE) -C e2e-tests test

# ------------------------------------------------------------
# Clean everything
# ------------------------------------------------------------
clean:
	$(MAKE) -C mod/secure-services clean
	$(MAKE) -C mod/uefi clean
	$(MAKE) -C e2e-tests clean

.PHONY: all secure-services secure-services-test uefi ec run_ec demo run run-in-devcontainer e2e-test clean
