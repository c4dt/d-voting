package integration

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/c4dt/d-voting/contracts/evoting"
	"github.com/c4dt/d-voting/dela"
	"github.com/c4dt/d-voting/dela/contracts/access"
	"github.com/c4dt/d-voting/dela/core/execution/native"
	"github.com/c4dt/d-voting/dela/core/ordering"
	"github.com/c4dt/d-voting/dela/core/txn"
	"github.com/c4dt/d-voting/dela/core/txn/signed"
	"github.com/c4dt/d-voting/dela/crypto"
	"golang.org/x/xerrors"
)

func newTxManager(signer crypto.Signer, firstNode dVotingCosiDela,
	timeout time.Duration, retry int) txManager {

	client := client{
		srvc: firstNode.GetOrdering(),
		mgr:  firstNode.GetValidationSrv(),
	}

	return txManager{
		m:     signed.NewManager(signer, client),
		n:     firstNode,
		t:     timeout,
		retry: retry,
	}
}

type txManager struct {
	m     txn.Manager
	n     dVotingCosiDela
	t     time.Duration
	retry int
}

// For integrationTest
func (m txManager) addAndWait(args ...txn.Arg) ([]byte, error) {
	for i := 0; i < m.retry; i++ {
		dela.Logger.Info().Msgf("Adding and waiting for tx to succeed: %d", i)
		sentTxn, err := m.m.Make(args...)
		if err != nil {
			return nil, xerrors.Errorf("failed to Make: %v", err)
		}

		ctx, cancel := context.WithTimeout(context.Background(), m.t)
		defer cancel()

		events := m.n.GetOrdering().Watch(ctx)

		err = m.n.GetPool().Add(sentTxn)
		if err != nil {
			fmt.Printf("Failed to add transaction: %v", err)
			continue
		}

		sentTxnID := sentTxn.GetID()

		accepted := isAccepted(events, sentTxnID)
		if accepted {
			return sentTxnID, nil
		}

		err = m.m.Sync()
		if err != nil {
			return nil, xerrors.Errorf("failed to sync: %v", err)
		}

		cancel()

		time.Sleep(time.Millisecond * (1 << i))
	}

	return nil, xerrors.Errorf("transaction not included after timeout: %v", args)
}

// isAccepted returns true if the transaction was included then accepted
func isAccepted(events <-chan ordering.Event, txID []byte) bool {
	for event := range events {
		for _, result := range event.Transactions {
			fetchedTxnID := result.GetTransaction().GetID()

			if bytes.Equal(txID, fetchedTxnID) {
				accepted, _ := event.Transactions[0].GetStatus()

				return accepted
			}
		}
	}

	return false
}

func grantAccess(m txManager, signer crypto.Signer) error {
	pubKeyBuf, err := signer.GetPublicKey().MarshalBinary()
	if err != nil {
		return xerrors.Errorf("failed to GetPublicKey: %v", err)
	}

	args := []txn.Arg{
		{Key: native.ContractArg, Value: []byte("go.dedis.ch/dela.Access")},
		{Key: access.GrantIDArg, Value: []byte(hex.EncodeToString([]byte(evoting.ContractUID)))},
		{Key: access.GrantContractArg, Value: []byte("go.dedis.ch/dela.Evoting")},
		{Key: access.GrantCommandArg, Value: []byte("all")},
		{Key: access.IdentityArg, Value: []byte(base64.StdEncoding.EncodeToString(pubKeyBuf))},
		{Key: access.CmdArg, Value: []byte(access.CmdSet)},
	}
	_, err = m.addAndWait(args...)
	if err != nil {
		return xerrors.Errorf("failed to grantAccess: %v", err)
	}

	return nil
}
