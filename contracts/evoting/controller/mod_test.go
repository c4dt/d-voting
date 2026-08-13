package controller

import (
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/c4dt/d-voting/dela/cli/node"
)

func TestController_OnStart(t *testing.T) {
	err := NewController().OnStart(node.FlagSet{}, nil)
	require.Nil(t, err)
}

func TestController_OnStop(t *testing.T) {
	err := NewController().OnStop(nil)
	require.Nil(t, err)
}
