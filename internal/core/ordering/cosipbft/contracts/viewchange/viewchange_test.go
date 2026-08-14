package viewchange

import (
	"testing"

	"github.com/c4dt/d-voting/dela/core/access"
	"github.com/c4dt/d-voting/dela/core/execution"
	"github.com/c4dt/d-voting/dela/core/execution/native"
	"github.com/c4dt/d-voting/dela/core/ordering/cosipbft/authority"
	"github.com/c4dt/d-voting/dela/core/store"
	"github.com/c4dt/d-voting/dela/core/txn"
	"github.com/c4dt/d-voting/dela/core/txn/signed"
	"github.com/c4dt/d-voting/dela/serde"
	"github.com/c4dt/d-voting/dela/testing/fake"
	"github.com/stretchr/testify/require"
)

func TestRegisterContract(t *testing.T) {
	srvc := native.NewExecution()

	RegisterContract(srvc, Contract{})
}

func TestNewTransaction(t *testing.T) {
	mgr := NewManager(signed.NewManager(fake.NewSigner(), fake.NewClient()))

	tx, err := mgr.Make(authority.New(nil, nil))
	require.NoError(t, err)
	require.NotNil(t, tx)
	require.Equal(t, "[]", string(tx.GetArg(AuthorityArg)))

	_, err = mgr.Make(badRoster{})
	require.EqualError(t, err, fake.Err("failed to serialize roster"))

	mgr.manager = badManager{}
	_, err = mgr.Make(authority.New(nil, nil))
	require.EqualError(t, err, fake.Err("creating transaction"))
}

func TestContract_Execute(t *testing.T) {
	fac := authority.NewFactory(fake.AddressFactory{}, fake.PublicKeyFactory{})

	contract := NewContract(fac, fakeAccess{})

	err := contract.Execute(fakeStore{}, makeStep(t, "[]"))
	require.NoError(t, err)

	err = contract.Execute(fakeStore{}, execution.Step{Previous: []txn.Transaction{makeTx(t, "")}})
	require.EqualError(t, err, "only one view change per block is allowed")

	contract.rosterFac = badRosterFac{}
	err = contract.Execute(fakeStore{}, makeStep(t, "[]"))
	require.EqualError(t, err, messageArgMissing)

	contract.rosterFac = fac
	err = contract.Execute(fakeStore{errGet: fake.GetError()}, makeStep(t, "[]"))
	require.EqualError(t, err, messageStorageEmpty)

	contract.rosterFac = badRosterFac{counter: fake.NewCounter(1)}
	err = contract.Execute(fakeStore{}, makeStep(t, "[]"))
	require.EqualError(t, err, messageStorageCorrupted)

	contract.rosterFac = fac
	err = contract.Execute(fakeStore{}, makeStep(t, "[{},{},{}]"))
	require.EqualError(t, err, messageTooManyChanges)

	err = contract.Execute(fakeStore{}, makeStep(t, "[{},{}]"))
	require.EqualError(t, err, "duplicate in roster: fake.Address[0]")

	err = contract.Execute(fakeStore{errSet: fake.GetError()}, makeStep(t, "[]"))
	require.EqualError(t, err, messageStorageFailure)

	contract.access = fakeAccess{err: fake.GetError()}
	err = contract.Execute(fakeStore{}, makeStep(t, "[]"))
	require.EqualError(t, err, "unauthorized identity: fake.PublicKey")
}

// -----------------------------------------------------------------------------
// Utility functions

func makeStep(t *testing.T, arg string) execution.Step {
	return execution.Step{Current: makeTx(t, arg)}
}

func makeTx(t *testing.T, arg string) txn.Transaction {
	args := []signed.TransactionOption{
		signed.WithArg(AuthorityArg, []byte(arg)),
		signed.WithArg(native.ContractArg, []byte(ContractName)),
	}

	tx, err := signed.NewTransaction(0, fake.PublicKey{}, args...)
	require.NoError(t, err)

	return tx
}

type fakeStore struct {
	store.Snapshot

	errGet error
	errSet error
}

func (snap fakeStore) Get(key []byte) ([]byte, error) {
	return []byte("[{}]"), snap.errGet
}

func (snap fakeStore) Set(key, value []byte) error {
	return snap.errSet
}

type badRosterFac struct {
	authority.Factory
	counter *fake.Counter
}

func (fac badRosterFac) AuthorityOf(serde.Context, []byte) (authority.Authority, error) {
	if fac.counter.Done() {
		return nil, fake.GetError()
	}

	fac.counter.Decrease()
	return nil, nil
}

type badRoster struct {
	authority.Authority
}

func (ro badRoster) Serialize(serde.Context) ([]byte, error) {
	return nil, fake.GetError()
}

type badManager struct {
	txn.Manager
}

func (badManager) Make(opts ...txn.Arg) (txn.Transaction, error) {
	return nil, fake.GetError()
}

type fakeAccess struct {
	access.Service

	err error
}

func (srvc fakeAccess) Match(store.Readable, access.Credential, ...access.Identity) error {
	return srvc.err
}
