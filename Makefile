.DELETE_ON_ERROR:
.PHONY: all
all: build/partybox-wake build/partybox-wake.config

build:
	mkdir -p $@

build/partybox-wake: PartyBoxWake.swift BluetoothAudio.swift Info.plist | build
	xcrun swiftc -O PartyBoxWake.swift BluetoothAudio.swift -o $@ \
	    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

# Initialize once. Subsequent builds preserve the local selection and wake history.
build/partybox-wake.config: | build/partybox-wake partybox-wake.config
	cp partybox-wake.config $@
	@if [ -f config.txt ]; then \
	    uuid=$$(sed -n '1p' config.txt); name=$$(sed -n '2p' config.txt); \
	    if [ -n "$$name" ]; then build/partybox-wake --save "$$uuid" "$$name"; \
	    else build/partybox-wake --save "$$uuid"; fi; \
	fi
