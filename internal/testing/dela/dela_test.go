package integration

import (
	"github.com/c4dt/d-voting/internal/core/access"
	"github.com/c4dt/d-voting/internal/core/ordering"
	"github.com/c4dt/d-voting/internal/core/txn"
	"github.com/c4dt/d-voting/internal/network/mino"
)

// dela defines the common interface for a Dela node.
type dela interface {
	Setup(string, ...dela)
	GetMino() mino.Mino
	GetOrdering() ordering.Service
	GetTxManager() txn.Manager
	GetAccessService() access.Service
}
