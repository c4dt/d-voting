// Package main provides a cli for crypto operations like generating keys or
// displaying specific key formats.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/c4dt/d-voting/internal/cli"
	"github.com/c4dt/d-voting/internal/cli/ucli"
	bls "github.com/c4dt/d-voting/internal/crypto/bls/command"
)

var builder cli.Builder = ucli.NewBuilder("crypto", nil)
var printer io.Writer = os.Stderr

func main() {
	err := run(os.Args, bls.Initializer{})
	if err != nil {
		fmt.Fprintf(printer, "%+v\n", err)
	}
}

func run(args []string, inits ...cli.Initializer) error {
	for _, init := range inits {
		init.SetCommands(builder)
	}

	app := builder.Build()
	err := app.Run(args)
	if err != nil {
		return err
	}

	return nil
}
