package neff

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"time"

	"go.dedis.ch/kyber/v3"

	"github.com/dedis/d-voting/contracts/evoting"
	electionTypes "github.com/dedis/d-voting/contracts/evoting/types"
	"github.com/dedis/d-voting/services/shuffle/neff/types"
	"go.dedis.ch/dela"
	"go.dedis.ch/dela/core/execution/native"
	"go.dedis.ch/dela/core/ordering"
	"go.dedis.ch/dela/core/txn"
	"go.dedis.ch/dela/core/txn/pool"
	"go.dedis.ch/dela/core/txn/signed"
	"go.dedis.ch/dela/crypto"
	"go.dedis.ch/dela/mino"
	jsondela "go.dedis.ch/dela/serde/json"
	"go.dedis.ch/kyber/v3/proof"
	shuffleKyber "go.dedis.ch/kyber/v3/shuffle"
	"go.dedis.ch/kyber/v3/suites"
	"golang.org/x/xerrors"
)

const watchTimeout = time.Second * 6

// const endShuffleTimeout = time.Second * 50

var suite = suites.MustFind("Ed25519")

// Handler represents the RPC executed on each node
//
// - implements mino.Handler
type Handler struct {
	mino.UnsupportedHandler
	me            mino.Address
	service       ordering.Service
	p             pool.Pool
	txmngr        txn.Manager
	shuffleSigner crypto.Signer
}

// NewHandler creates a new handler
func NewHandler(me mino.Address, service ordering.Service, p pool.Pool,
	txmngr txn.Manager, shuffleSigner crypto.Signer) *Handler {
	return &Handler{
		me:            me,
		service:       service,
		p:             p,
		txmngr:        txmngr,
		shuffleSigner: shuffleSigner,
	}
}

// Stream implements mino.Handler. It allows one to stream messages to the
// players.
func (h *Handler) Stream(out mino.Sender, in mino.Receiver) error {

	from, msg, err := in.Recv(context.Background())
	if err != nil {
		return xerrors.Errorf("failed to receive: %v", err)
	}

	dela.Logger.Trace().Msgf("message received from: %v", from)

	switch msg := msg.(type) {
	case types.StartShuffle:
		err := h.handleStartShuffle(msg.GetElectionId())
		if err != nil {
			return xerrors.Errorf("failed to handle StartShuffle message: %v", err)
		}
	default:
		return xerrors.Errorf("expected StartShuffle message, got: %T", msg)
	}

	return nil
}

func (h *Handler) handleStartShuffle(electionID string) error {
	dela.Logger.Info().Msg("Starting the neff shuffle protocol ...")

	// loop until the threshold is reached or our transaction has been accepted
	for {
		election, err := getElection(h.service, electionID)
		if err != nil {
			return xerrors.Errorf("failed to get election: %v", err)
		}

		round := len(election.ShuffleInstances)

		// check if the threshold is reached
		if round >= election.ShuffleThreshold {
			dela.Logger.Info().Msgf("shuffle done with round n°%d", round)
			return nil
		}

		if election.Status != electionTypes.Closed {
			return xerrors.Errorf("the election must be closed: but status is %v", election.Status)
		}

		tx, err := makeTx(election, h.txmngr, h.shuffleSigner)
		if err != nil {
			return xerrors.Errorf("failed to make tx: %v", err)
		}

		watchCtx, cancel := context.WithTimeout(context.Background(), watchTimeout)
		defer cancel()

		events := h.service.Watch(watchCtx)

		err = h.p.Add(tx)
		if err != nil {
			return xerrors.Errorf("failed to add transaction to the pool: %v", err.Error())
		}

		accepted, msg := watchTx(events, tx.GetID())

		if !accepted {
			err = h.txmngr.Sync()
			if err != nil {
				return xerrors.Errorf("failed to sync manager: %v", err.Error())
			}
		}

		if accepted {
			dela.Logger.Info().Msg("our shuffling contribution has " +
				"been accepted, we are exiting the process")

			return nil
		}

		dela.Logger.Info().Msg("shuffling contribution denied : " + msg)
	}
}

func makeTx(election *electionTypes.Election, manager txn.Manager, shuffleSigner crypto.Signer) (txn.Transaction, error) {
	shuffledBallots, getProver, err := getShuffledBallots(election)
	if err != nil {
		return nil, xerrors.Errorf("failed to get shuffled ballots: %v", err)
	}

	shuffleBallotsTransaction := electionTypes.ShuffleBallotsTransaction{
		ElectionID:      election.ElectionID,
		Round:           len(election.ShuffleInstances),
		ShuffledBallots: shuffledBallots,
	}

	shuffleHash, err := shuffleBallotsTransaction.HashShuffle(election.ElectionID)
	if err != nil {
		return nil, xerrors.Errorf("Could not hash the shuffle while creating transaction: %v", err)
	}

	// Generate random vector and proof
	semiRandomStream, err := evoting.NewSemiRandomStream(shuffleHash)
	if err != nil {
		return nil, xerrors.Errorf("could not create semi-random stream: %v", err)
	}

	e := make([]kyber.Scalar, election.ChunksPerBallot())
	for i := 0; i < election.ChunksPerBallot(); i++ {
		v := suite.Scalar().Pick(semiRandomStream)
		e[i] = v
	}

	prover, err := getProver(e)
	if err != nil {
		return nil, xerrors.Errorf("could not get prover for shuffle : %v", err)
	}

	shuffleProof, err := proof.HashProve(suite, protocolName, prover)
	if err != nil {
		return nil, xerrors.Errorf("shuffle proof failed: %v", err)
	}

	shuffleBallotsTransaction.Proof = shuffleProof

	shuffleBallotsTransaction.RandomVector = electionTypes.RandomVector{}

	err = shuffleBallotsTransaction.RandomVector.LoadFromScalars(e)
	if err != nil {
		return nil, xerrors.Errorf("could not marshal shuffle random vector")
	}

	// Sign the shuffle:

	signature, err := shuffleSigner.Sign(shuffleHash)
	if err != nil {
		return nil, xerrors.Errorf("Could not sign the shuffle : %v", err)
	}

	encodedSignature, err := signature.Serialize(jsondela.NewContext())
	if err != nil {
		return nil, xerrors.Errorf("Could not encode signature as []byte : %v ", err)
	}

	publicKey, err := shuffleSigner.GetPublicKey().MarshalBinary()
	if err != nil {
		return nil, xerrors.Errorf("Could not unmarshal public key from nodeSigner: %v", err)
	}

	// Complete transaction:
	shuffleBallotsTransaction.PublicKey = publicKey
	shuffleBallotsTransaction.Signature = encodedSignature

	js, err := json.Marshal(shuffleBallotsTransaction)
	if err != nil {
		return nil, xerrors.Errorf("failed to marshal "+
			"ShuffleBallotsTransaction: %v", err.Error())
	}

	args := make([]txn.Arg, 3)
	args[0] = txn.Arg{
		Key:   native.ContractArg,
		Value: []byte(evoting.ContractName),
	}
	args[1] = txn.Arg{
		Key:   evoting.CmdArg,
		Value: []byte(evoting.CmdShuffleBallots),
	}
	args[2] = txn.Arg{
		Key:   evoting.ShuffleBallotsArg,
		Value: js,
	}

	tx, err := manager.Make(args...)
	if err != nil {
		return nil, xerrors.Errorf("failed to use manager: %v", err.Error())
	}

	return tx, nil
}

// getShuffledBallots returns the shuffled ballots with the shuffling proof.
func getShuffledBallots(election *electionTypes.Election) ([]electionTypes.EncryptedBallot,
	func(e []kyber.Scalar) (proof.Prover, error), error) {

	round := len(election.ShuffleInstances)

	var encryptedBallots electionTypes.EncryptedBallots

	if round == 0 {
		encryptedBallots = election.PublicBulletinBoard.Ballots
	} else {
		encryptedBallots = election.ShuffleInstances[round-1].ShuffledBallots
	}

	X, Y, err := encryptedBallots.GetElGPairs()
	if err != nil {
		return nil, nil, xerrors.Errorf("failed to get X, Y: %v", err)
	}

	pubKey := suite.Point()

	err = pubKey.UnmarshalBinary(election.Pubkey)
	if err != nil {
		return nil, nil, xerrors.Errorf("couldn't unmarshal public key: %v", err)
	}

	// shuffle sequences
	XX, YY, getProver := shuffleKyber.SequencesShuffle(suite, nil, pubKey, X, Y, suite.RandomStream())

	var shuffledBallots electionTypes.EncryptedBallots

	err = shuffledBallots.InitFromElGPairs(XX, YY)
	if err != nil {
		return nil, nil, xerrors.Errorf("failed to init ciphertexts: %v", err)
	}

	return shuffledBallots, getProver, nil
}

// watchTx checks the transaction to find one that match txID. Return if the
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

// getElection returns the election state from the global state.
func getElection(service ordering.Service, electionID string) (*electionTypes.Election, error) {
	electionIDBuff, err := hex.DecodeString(electionID)
	if err != nil {
		return nil, xerrors.Errorf("failed to decode election id: %v", err)
	}

	prf, err := service.GetProof(electionIDBuff)
	if err != nil {
		return nil, xerrors.Errorf("failed to read on the blockchain: %v", err)
	}

	election := new(electionTypes.Election)

	err = json.NewDecoder(bytes.NewBuffer(prf.GetValue())).Decode(election)
	if err != nil {
		return nil, xerrors.Errorf("failed to unmarshal Election: %v", err)
	}
	return election, nil
}

// getManager is the function called when we need a transaction manager. It
// allows us to use a different manager for the tests.
var getManager = func(signer crypto.Signer, s signed.Client) txn.Manager {
	return signed.NewManager(signer, s)
}
