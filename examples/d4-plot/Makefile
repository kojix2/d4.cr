CRYSTAL ?= crystal
SHARDS ?= shards

BIN := bin/d4-plot
SRC := src/d4-plot.cr

.PHONY: all deps build run clean

all: build

deps:
	@test -d lib/uing || $(SHARDS) install

build: deps
	@mkdir -p bin
	$(CRYSTAL) build "$(SRC)" -o "$(BIN)"

run: build
	"$(BIN)"

clean:
	rm -f "$(BIN)"
