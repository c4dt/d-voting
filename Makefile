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
	go install ./internal/testing/mcheck && \
	go vet -vettool=`go env GOPATH`/bin/mcheck -commentLen -ifInit ./...

# target to run all the possible checks except integration; it's a good habit to
# run it before pushing code
check: lint vet
	go test `go list ./... | grep -v /integration`

test_integration:
	go test ./integration -timeout 50s

build:
	go build -ldflags="-X $(versionFlag) -X $(timeFlag)" -o dvoting ./cmd/dvoting
	GOOS=linux GOARCH=amd64 go build -ldflags="-X $(versionFlag) -X $(timeFlag)" -o dvoting-linux-amd64-$(versionFile) ./cmd/dvoting
	GOOS=darwin GOARCH=amd64 go build -ldflags="-X $(versionFlag) -X $(timeFlag)" -o dvoting-darwin-amd64-$(versionFile) ./cmd/dvoting
	GOOS=windows GOARCH=amd64 go build -ldflags="-X $(versionFlag) -X $(timeFlag)" -o dvoting-windows-amd64-$(versionFile) ./cmd/dvoting



.PHONY: tidy test-flaky

# tidy runs go mod tidy pinned to the Go version declared in go.mod.
tidy:
	@go mod tidy -go="1.25.0"

# Flaky tests that need retries 
# It first runs all the tests in "short" mode, so the flaky tests don't run.
# Then the flaky tests get run separately for at most 3 times, and hopefully it all works out.
FLAKY_TESTS_PBFT := (TestService_Scenario_Basic|TestService_Scenario_ViewChange|TestService_Scenario_FinalizeFailure)
FLAKY_TESTS_MINOWS := (Test_session_Recv_SessionEnded|Test_session_Send_SessionEnded)

# test runs the flaky tests without coverage, retrying each up to 3 times.
test-flaky: tidy
	@for count in $$( seq 4 ); do \
		if [ "$$count" -eq 4 ]; then \
			echo "Couldn't run all flaky tests in 3 tries"; \
			exit 1; \
		fi; \
		echo "Running $$count/3"; \
		if ! go test -count=1 ./internal/network/mino/minows -run="${FLAKY_TESTS_MINOWS}"; then \
			continue; \
		fi; \
		if ! go test -count=1 ./internal/core/ordering/cosipbft -run="${FLAKY_TESTS_PBFT}"; then \
			continue; \
		fi; \
		break; \
	done
