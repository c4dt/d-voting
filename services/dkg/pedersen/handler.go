package pedersen

import (
	"bytes"
	"crypto/sha256"

	"go.dedis.ch/dela/core/ordering"
	"go.dedis.ch/dela/core/txn"
	"go.dedis.ch/dela/crypto"

	"go.dedis.ch/dela"
	"go.dedis.ch/dela/core/execution/native"
	"go.dedis.ch/dela/serde"
	jsondela "go.dedis.ch/dela/serde/json"
	"golang.org/x/xerrors"

	"github.com/c4dt/d-voting/contracts/evoting"
	etypes "github.com/c4dt/d-voting/contracts/evoting/types"
)

// HandlerData is used to synchronise actors between the DKG and the filesystem.
// The opaque dela snapshot bytes are stored in Snapshot; the adapter does not
// interpret them.
type HandlerData struct {
	// Version of the persistence format.
	Version uint16
	// Snapshot is the opaque bytes returned by dela's MarshalBinary.
	Snapshot []byte
}

// NewHandlerData generates new actor data.
func NewHandlerData() HandlerData {
	return HandlerData{
		Version: 1,
	}
}

// watchTx checks the transaction to find one that match txID. Returns if the
// transaction has been accepted or not. Will also return false if/when the
// events chan is closed, which is expected to happen.
func watchTx(events <-chan ordering.Event, txID []byte) (bool, string) {
	for event := range events {
		for _, res := range event.Transactions {
			if !bytes.Equal(res.GetTransaction().GetID(), txID) {
				continue
			}

			dela.Logger.Info().Hex("id", txID).Msg("transaction included in the block")

			accepted, msg := res.GetStatus()
			if accepted {
				return true, ""
			}

			return false, msg
		}
	}

	return false, "watch timeout"
}

func makeTx(ctx serde.Context, form *etypes.Form, pubShares etypes.PubsharesUnit,
	index int,
	manager txn.Manager,
	pubSharesSigner crypto.Signer) (txn.Transaction, error) {

	pubShareTx := etypes.RegisterPubShares{
		FormID:    form.FormID,
		Pubshares: pubShares,
		Index:     index,
	}

	h := sha256.New()

	err := pubShareTx.Fingerprint(h)
	if err != nil {
		return nil, xerrors.Errorf("failed to get fingerprint: %v", err)
	}

	hash := h.Sum(nil)

	// Sign the pubShares :
	signature, err := pubSharesSigner.Sign(hash)
	if err != nil {
		return nil, xerrors.Errorf("could not sign the pubShares : %v", err)
	}

	pubKey, err := pubSharesSigner.GetPublicKey().MarshalBinary()
	if err != nil {
		return nil, xerrors.Errorf("could not marshal signer's public key: %v", err)
	}

	encodedSignature, err := signature.Serialize(jsondela.NewContext())
	if err != nil {
		return nil, xerrors.Errorf("Could not encode signature as []byte : %v ", err)
	}

	// Complete transaction:
	pubShareTx.Signature = encodedSignature
	pubShareTx.PublicKey = pubKey

	data, err := pubShareTx.Serialize(ctx)
	if err != nil {
		return nil, xerrors.Errorf("failed to serialize register pubShares: %v", err)
	}

	args := make([]txn.Arg, 3)
	args[0] = txn.Arg{
		Key:   native.ContractArg,
		Value: []byte(evoting.ContractName),
	}
	args[1] = txn.Arg{
		Key:   evoting.CmdArg,
		Value: []byte(evoting.CmdRegisterPubShares),
	}
	args[2] = txn.Arg{
		Key:   evoting.FormArg,
		Value: data,
	}

	tx, err := manager.Make(args...)
	if err != nil {
		return nil, xerrors.Errorf("failed to use manager: %v", err.Error())
	}

	return tx, nil
}
