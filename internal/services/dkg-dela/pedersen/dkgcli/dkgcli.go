package main

import (
	"fmt"
	"io"
	"os"

	"github.com/c4dt/d-voting/dela/cli/node"

	db "github.com/c4dt/d-voting/dela/core/store/kv/controller"
	dkg "github.com/c4dt/d-voting/dela/dkg/pedersen/controller"
	mino "github.com/c4dt/d-voting/dela/mino/minogrpc/controller"
)

func main() {
	err := run(os.Args)
	if err != nil {
		fmt.Printf("%+v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	return runWithCfg(args, config{Writer: os.Stdout})
}

type config struct {
	Channel chan os.Signal
	Writer  io.Writer
}

func runWithCfg(args []string, cfg config) error {
	builder := node.NewBuilderWithCfg(
		cfg.Channel,
		cfg.Writer,
		db.NewController(),
		mino.NewController(),
		dkg.NewMinimal(),
	)

	app := builder.Build()

	err := app.Run(args)
	if err != nil {
		return err
	}

	return nil
}
