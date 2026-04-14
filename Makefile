.PHONY: test
test:
	flow test --cover --covercode="contracts" --coverprofile="coverage.lcov" ./cadence/tests/*_test.cdc

.PHONY: lint
lint:
	find cadence -name "*.cdc" | xargs flow cadence lint --warnings-as-errors

.PHONY: ci
ci: lint test
