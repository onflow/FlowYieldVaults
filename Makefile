.PHONY: test
test:
	flow test --cover --covercode="contracts" --coverprofile="coverage.lcov" ./cadence/tests/*_test.cdc

.PHONY: lint
lint:
	find cadence -name "*.cdc" | xargs flow cadence lint \
		| tee /dev/stderr | tail -n2 | grep -q "Lint passed"

.PHONY: ci
ci: lint test
