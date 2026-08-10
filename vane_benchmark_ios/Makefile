# One-command runner for the iOS Simulator benchmark. TEST_RUNNER_-prefixed
# variables must live in xcodebuild's ENVIRONMENT (they are ignored as
# command-line build settings), which is why this recipe uses `env`.
DEVICE ?= iPhone 17 Pro
OS ?= 26.1
BASE_URL ?= https://cloudflare-quic.com

bench:
	env TEST_RUNNER_VANE_TEST_BASE_URL=$(BASE_URL) \
	    TEST_RUNNER_VANE_BENCH_JSON=$(CURDIR)/results/latest.json \
	    xcodebuild test \
	    -scheme vane_benchmark_ios-Package \
	    -destination 'platform=iOS Simulator,name=$(DEVICE),OS=$(OS)'

# Host-side smoke run (macOS, NOT the deliverable): same harness, plain env.
bench_macos:
	env VANE_TEST_BASE_URL=$(BASE_URL) \
	    VANE_BENCH_JSON=$(CURDIR)/results/latest-macos.json \
	    swift test
