BIN = bin
SWIFT = swiftc -O -swift-version 5
TOOLS = $(BIN)/rt_stress $(BIN)/na_stress $(BIN)/ane_stress $(BIN)/fused_stress $(BIN)/membw $(BIN)/throttlewatch $(BIN)/hidtemps

all: $(TOOLS)

$(BIN):
	mkdir -p $(BIN)

$(BIN)/rt_stress $(BIN)/na_stress $(BIN)/fused_stress: $(BIN)/%: src/%.swift | $(BIN)
	$(SWIFT) $< -o $@ -framework Metal

$(BIN)/ane_stress: src/ane_stress.swift | $(BIN)
	$(SWIFT) $< -o $@

$(BIN)/membw: src/membw.c | $(BIN)
	clang -O3 -Wall $< -o $@

$(BIN)/throttlewatch: tools/throttlewatch.c | $(BIN)
	clang -O2 -Wall $< -o $@ -framework CoreFoundation -lIOReport

$(BIN)/hidtemps: tools/hidtemps.c | $(BIN)
	clang -O2 -Wall $< -o $@ -framework CoreFoundation -framework IOKit

clean:
	rm -rf $(BIN)

.PHONY: all clean
