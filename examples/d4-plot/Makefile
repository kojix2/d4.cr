CRYSTAL ?= crystal
CARGO ?= cargo
SHARDS ?= shards
GIT ?= git

D4_DIR ?= ../../d4-format
D4_REPO ?= https://github.com/38/d4-format.git
D4_TARGET_DIR := $(D4_DIR)/target/release
D4_STATIC_LIB := $(D4_TARGET_DIR)/libd4binding.a
D4_FDOPEN_PATCH := patches/d4-format-zlib-fdopen.patch

BUILD_DIR := build
STATIC_LIB_DIR := $(BUILD_DIR)/static-libs
STATIC_LIB := $(STATIC_LIB_DIR)/libd4binding.a
BIN_DIR := bin
BIN := $(BIN_DIR)/d4-plot
SRC := src/d4-plot.cr

CRYSTAL_LINK_FLAGS := -L$(abspath $(STATIC_LIB_DIR))
UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
CRYSTAL_LINK_FLAGS += -framework SystemConfiguration -framework CoreFoundation -framework Security
endif

.PHONY: all deps d4-format patch-d4-format d4binding build run clean distclean

all: build

deps:
	$(SHARDS) install

d4-format:
	@test -d "$(D4_DIR)" || $(GIT) clone --depth 1 "$(D4_REPO)" "$(D4_DIR)"

patch-d4-format: d4-format
	@if $(GIT) -C "$(D4_DIR)" apply --reverse --check "$(abspath $(D4_FDOPEN_PATCH))" >/dev/null 2>&1; then \
	  echo "d4-format zlib fdopen patch already applied"; \
	else \
	  $(GIT) -C "$(D4_DIR)" apply "$(abspath $(D4_FDOPEN_PATCH))"; \
	fi

d4binding: patch-d4-format
	$(CARGO) build --release -p d4binding --manifest-path "$(D4_DIR)/Cargo.toml"
	@test -f "$(D4_STATIC_LIB)" || (echo "missing $(D4_STATIC_LIB); d4binding did not produce a static library" >&2; exit 1)
	@mkdir -p "$(STATIC_LIB_DIR)"
	cp "$(D4_STATIC_LIB)" "$(STATIC_LIB)"

build: deps d4binding
	@mkdir -p "$(BIN_DIR)"
	CRYSTAL_LIBRARY_PATH="$(abspath $(STATIC_LIB_DIR))" \
	  $(CRYSTAL) build "$(SRC)" -o "$(BIN)" --link-flags="$(CRYSTAL_LINK_FLAGS)"

run: build
	"$(BIN)"

clean:
	rm -rf "$(BUILD_DIR)" "$(BIN_DIR)"

distclean: clean
	rm -rf lib shard.lock
