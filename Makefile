IMAGE_E2E := flow-yield-vaults-e2e

.PHONY: test-e2e

test-e2e:
	docker build -f Dockerfile.e2e -t $(IMAGE_E2E) .
	docker run --rm $(IMAGE_E2E)
