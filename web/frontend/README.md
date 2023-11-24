# Automated Tests w/ Playwright

## Setup

Run

```
npx playwright install-deps --dry-run
```

to be shown the dependencies that you need to install on your machine (requires `root` access).

## Run tests

Run

```
npx playwright test
```

to run the tests. This will open a window in your browser w/ the test results.

To run interactive tests, run

```
npx playwright test --ui
```

this will open an user interface where you can interactively run and evaluate tests.
