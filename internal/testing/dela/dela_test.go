package integration

import (
	"github.com/c4dt/d-voting/dela/core/access"
	"github.com/c4dt/d-voting/dela/core/ordering"
	"github.com/c4dt/d-voting/dela/core/txn"
	"github.com/c4dt/d-voting/dela/mino"
)

// dela defines the common interface for a Dela node.
type dela interface {
	Setup(string, ...dela)
	GetMino() mino.Mino
	GetOrdering() ordering.Service
	GetTxManager() txn.Manager
	GetAccessService() access.Service
}
