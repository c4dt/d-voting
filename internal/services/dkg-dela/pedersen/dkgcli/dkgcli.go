package main

import (
	"fmt"
	"io"
	"os"

	"github.com/c4dt/d-voting/internal/cli/node"

	db "github.com/c4dt/d-voting/internal/core/store/kv/controller"
	mino "github.com/c4dt/d-voting/internal/network/mino/minogrpc/controller"
	dkg "github.com/c4dt/d-voting/internal/services/dkg-dela/pedersen/controller"
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
