version=$(shell git describe --abbrev=0 --tags || echo '0.0.0')
versionFlag="github.com/c4dt/d-voting.Version=$(version)"
versionFile=$(shell echo $(version) | tr . _)
timeFlag="github.com/c4dt/d-voting.BuildTime=$(shell date +'%d/%m/%y_%H:%M')"

lint:
	# Coding style static check.
	@GOTOOLCHAIN=go1.25.0 go install honnef.co/go/tools/cmd/staticcheck@v0.7.0
	@go mod tidy
	staticcheck ./...
#	golint -set_exit_status ./...

vet:
	@echo "⚠️ Warning: the following only works with go >= 1.14" && \
	go install ./internal/mcheck && \
	go vet -vettool=`go env GOPATH`/bin/mcheck -commentLen -ifInit ./...

# target to run all the possible checks except integration; it's a good habit to
# run it before pushing code
check: lint vet
	go test `go list ./... | grep -v /integration`

test_integration:
	go test ./integration -timeout 50s

build:
	go build -ldflags="-X $(versionFlag) -X $(timeFlag)" -o dvoting ./cli/dvoting
	GOOS=linux GOARCH=amd64 go build -ldflags="-X $(versionFlag) -X $(timeFlag)" -o dvoting-linux-amd64-$(versionFile) ./cli/dvoting
	GOOS=darwin GOARCH=amd64 go build -ldflags="-X $(versionFlag) -X $(timeFlag)" -o dvoting-darwin-amd64-$(versionFile) ./cli/dvoting
	GOOS=windows GOARCH=amd64 go build -ldflags="-X $(versionFlag) -X $(timeFlag)" -o dvoting-windows-amd64-$(versionFile) ./cli/dvoting



# ------------------------------------------------------------
# DELA targets
# ------------------------------------------------------------

.PHONY: dela-all tidy generate-dela lint-dela tests-dela test-dela coverage-dela

export PATH := $(shell go env GOPATH)/bin:$(PATH)

# Default DELA target to check locally that everything is ok, BEFORE pushing remotely
dela-all: generate-dela lint-dela test-dela
	@echo "Done with the standard DELA checks"

tidy:
	@go mod tidy -go="1.25.0"

generate-dela: tidy
	go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.5
	go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
	go generate ./dela/...

lint-dela: tidy
	@echo "Running golangci-lint for DELA"
	@GOTOOLCHAIN=go1.25.0 go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.64.8
	golangci-lint run --config dela/.golangci.yml ./dela/...

tests-dela:
	while make test-dela; do echo "Testing again at $$(date)"; done; echo "Failed testing"

FLAKY_TESTS_PBFT := (TestService_Scenario_Basic|TestService_Scenario_ViewChange|TestService_Scenario_FinalizeFailure)
FLAKY_TESTS_MINOWS := (Test_session_Recv_SessionEnded)

# test runs all tests in DELA without coverage
# It first runs all the tests in "short" mode, so the flaky tests don't run.
# Then the flaky tests get run separately for at most 3 times, and hopefully it all works out.
test-dela: tidy
	go test ./dela/... -short -count=1 || exit 1
	@for count in $$( seq 4 ); do \
		if [ "$$count" -eq 4 ]; then \
			echo "Couldn't run all flaky tests in 3 tries"; \
			exit 1; \
		fi; \
		echo "Running $$count/3"; \
		if ! go test -count=1 ./dela/mino/minows -run="${FLAKY_TESTS_MINOWS}"; then \
			continue; \
		fi; \
		if ! go test -count=1 ./dela/core/ordering/cosipbft -run="${FLAKY_TESTS_PBFT}"; then \
			continue; \
		fi; \
		break; \
	done

# test runs all tests in DELA and generates coverage output (to be used by SonarCloud)
coverage-dela: tidy
	go test -json -covermode=count -coverprofile=dela/profile.cov ./dela/... | tee dela/report.json
