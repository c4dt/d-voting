package controller

import (
	"testing"

	"go.dedis.ch/dela/cli/node"
	"github.com/stretchr/testify/require"
)

func TestController_OnStart(t *testing.T) {
	err := NewController().OnStart(node.FlagSet{}, nil)
	require.Nil(t, err)
}

func TestController_OnStop(t *testing.T) {
	err := NewController().OnStop(nil)
	require.Nil(t, err)
}
