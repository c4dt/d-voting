package neff

import (
	"encoding/hex"
	"strconv"
	"testing"

	"go.dedis.ch/dela/serde/json"

	"github.com/c4dt/d-voting/services/shuffle/neff/types"
	"go.dedis.ch/kyber/v3"

	etypes "github.com/c4dt/d-voting/contracts/evoting/types"
	"github.com/c4dt/d-voting/internal/testing/fake"
	"go.dedis.ch/dela/core/access"
	"go.dedis.ch/dela/core/txn/signed"
	"go.dedis.ch/dela/mino"
	"github.com/stretchr/testify/require"
	"go.dedis.ch/kyber/v3/util/random"
	"golang.org/x/xerrors"
)

func TestHandler_Stream(t *testing.T) {
	handler := Handler{}

	receiver := fake.NewBadReceiver()

	err := handler.Stream(fake.Sender{}, receiver)
	require.EqualError(t, err, fake.Err("failed to receive"))

	receiver = fake.NewReceiver(
		fake.NewRecvMsg(fake.NewAddress(0), fake.Message{}),
	)
	err = handler.Stream(fake.Sender{}, receiver)
	require.EqualError(t, err, "expected StartShuffle message, got: fake.Message")

	receiver = fake.NewReceiver(fake.NewRecvMsg(fake.NewAddress(0),
		types.NewStartShuffle("dummyID", make([]mino.Address, 0))))

	handler.txmngr = fake.Manager{}

	err = handler.Stream(fake.Sender{}, receiver)
	require.EqualError(t, err, "failed to handle StartShuffle message: failed "+
		"to get form: failed to decode formIDHex: encoding/hex: invalid byte: U+0075 'u'")

	//Test successful Shuffle round from message:
	dummyID := hex.EncodeToString([]byte("dummyId"))
	handler = initValidHandler(dummyID)

	receiver = fake.NewReceiver(fake.NewRecvMsg(fake.NewAddress(0), types.NewStartShuffle(dummyID, make([]mino.Address, 0))))
	err = handler.Stream(fake.Sender{}, receiver)

	require.NoError(t, err)

}

func TestHandler_StartShuffle(t *testing.T) {
	// Some initialization:
	k := 3

	Ks, Cs, pubKey := fakeKCPoints(k)

	fakeErr := xerrors.Errorf("fake error")

	handler := Handler{
		me: fake.NewAddress(0),
	}
	dummyID := hex.EncodeToString([]byte("dummyId"))

	// Service not working:
	badService := fake.Service{
		Err:   fakeErr,
		Forms: nil,
	}
	handler.service = &badService
	handler.txmngr = fake.Manager{}

	err := handler.handleStartShuffle(dummyID)
	require.EqualError(t, err, "failed to get form: failed to get proof: fake error")

	Forms := make(map[string]etypes.Form)

	// Form does not exist
	service := fake.Service{
		Err:     nil,
		Forms:   Forms,
		Context: json.NewContext(),
	}
	handler.service = &service

	err = handler.handleStartShuffle(dummyID)
	require.EqualError(t, err, "failed to get form: form does not exist")

	// Form still opened:
	form := etypes.Form{
		FormID:           dummyID,
		Status:           0,
		Pubkey:           nil,
		Suffragia:        etypes.Suffragia{},
		ShuffleInstances: []etypes.ShuffleInstance{},
		DecryptedBallots: nil,
		ShuffleThreshold: 1,
		BallotSize:       1,
		Roster:           fake.Authority{},
	}

	service = updateService(form, dummyID)
	handler.service = &service
	handler.context = serdecontext
	handler.formFac = formFac

	err = handler.handleStartShuffle(dummyID)
	require.EqualError(t, err, "the form must be closed: (0)")

	// Wrong formatted ballots:
	form.Status = etypes.Closed

	deleteUserFromSuffragia := func(suff *etypes.Suffragia, userID string) bool {
		for i, u := range suff.UserIDs {
			if u == userID {
				suff.UserIDs = append(suff.UserIDs[:i], suff.UserIDs[i+1:]...)
				suff.Ciphervotes = append(suff.Ciphervotes[:i], suff.Ciphervotes[i+1:]...)
				return true
			}
		}

		return false
	}

	deleteUserFromSuffragia(&form.Suffragia, "fakeUser")

	// Valid Ballots, bad form.PubKey
	for i := 0; i < k; i++ {
		ballot := etypes.Ciphervote{etypes.EGPair{
			K: Ks[i],
			C: Cs[i],
		},
		}
		form.Suffragia.CastVote("dummyUser"+strconv.Itoa(i), ballot)
	}

	service = updateService(form, dummyID)

	handler.service = &service

	// Wrong shuffle signer
	form.Pubkey = pubKey

	service = updateService(form, dummyID)
	handler.service = &service

	handler.shuffleSigner = fake.NewBadSigner()

	err = handler.handleStartShuffle(dummyID)
	require.EqualError(t, err, fake.Err("failed to make tx: could not sign the shuffle "))

	// Bad common signer :
	service = updateService(form, dummyID)

	handler.service = &service
	handler.shuffleSigner = fake.NewSigner()

	// Bad manager

	handler.txmngr = fake.Manager{}

	err = handler.handleStartShuffle(dummyID)
	require.EqualError(t, err, fake.Err("failed to make tx: failed to use manager"))

	manager := signed.NewManager(fake.NewSigner(), fakeClient{})

	handler.txmngr = manager

	// Valid, basic scenario : (all errors fixed)
	fakePool := fake.Pool{Service: &service}

	handler.service = &service
	handler.p = &fakePool

	err = handler.handleStartShuffle(dummyID)
	require.NoError(t, err)

	// Threshold is reached :
	form.ShuffleThreshold = 0
	service = updateService(form, dummyID)
	fakePool = fake.Pool{Service: &service}
	handler.service = &service

	err = handler.handleStartShuffle(dummyID)
	require.NoError(t, err)

	// Service not working :
	form.ShuffleThreshold = 1

	Forms = make(map[string]etypes.Form)
	Forms[dummyID] = form

	service = updateService(form, dummyID)
	fakePool = fake.Pool{Service: &service}

	handler.service = &service
	err = handler.handleStartShuffle(dummyID)
	// all transactions got denied
	require.NoError(t, err)

	// Shuffle already started:
	shuffledBallots := append([]etypes.Ciphervote{}, form.Suffragia.Ciphervotes...)

	form.ShuffleInstances = append(form.ShuffleInstances,
		etypes.ShuffleInstance{ShuffledBallots: shuffledBallots})

	form.ShuffleThreshold = 2

	service = updateService(form, dummyID)
	fakePool = fake.Pool{Service: &service}
	handler = *NewHandler(handler.me, &service, &fakePool, manager,
		handler.shuffleSigner, serdecontext, formFac)

	err = handler.handleStartShuffle(dummyID)
	require.NoError(t, err)
}

// -----------------------------------------------------------------------------
// Utility functions
func updateService(form etypes.Form, dummyID string) fake.Service {
	Forms := make(map[string]etypes.Form)
	Forms[dummyID] = form

	return fake.Service{
		Err:     nil,
		Forms:   Forms,
		Pool:    nil,
		Status:  false,
		Channel: nil,
		Context: json.NewContext(),
	}
}

func initValidHandler(dummyID string) Handler {
	handler := Handler{}

	form := initFakeForm(dummyID)

	Forms := make(map[string]etypes.Form)
	Forms[dummyID] = form

	service := fake.Service{
		Err:     nil,
		Forms:   Forms,
		Status:  true,
		Context: json.NewContext(),
	}
	fakePool := fake.Pool{Service: &service}

	handler.service = &service
	handler.p = &fakePool
	handler.me = fake.NewAddress(0)
	handler.shuffleSigner = fake.NewSigner()
	handler.txmngr = signed.NewManager(fake.NewSigner(), fakeClient{})
	handler.context = serdecontext
	handler.formFac = formFac

	return handler
}

func initFakeForm(formID string) etypes.Form {
	k := 3
	KsMarshalled, CsMarshalled, pubKey := fakeKCPoints(k)
	form := etypes.Form{
		FormID:           formID,
		Status:           etypes.Closed,
		Pubkey:           pubKey,
		Suffragia:        etypes.Suffragia{},
		ShuffleInstances: []etypes.ShuffleInstance{},
		DecryptedBallots: nil,
		ShuffleThreshold: 1,
		BallotSize:       1,
		Roster:           fake.Authority{},
	}

	for i := 0; i < k; i++ {
		ballot := etypes.Ciphervote{etypes.EGPair{
			K: KsMarshalled[i],
			C: CsMarshalled[i],
		},
		}
		form.Suffragia.CastVote("dummyUser"+strconv.Itoa(i), ballot)
	}
	return form
}

func fakeKCPoints(k int) ([]kyber.Point, []kyber.Point, kyber.Point) {
	RandomStream := suite.RandomStream()
	h := suite.Scalar().Pick(RandomStream)
	pubKey := suite.Point().Mul(h, nil)

	Ks := make([]kyber.Point, 0, k)
	Cs := make([]kyber.Point, 0, k)

	for i := 0; i < k; i++ {
		// Embed the message into a curve point
		message := "Ballot" + strconv.Itoa(i)
		M := suite.Point().Embed([]byte(message), random.New())

		// ElGamal-encrypt the point to produce ciphertext (K,C).
		k := suite.Scalar().Pick(random.New()) // ephemeral private key
		K := suite.Point().Mul(k, nil)         // ephemeral DH public key
		S := suite.Point().Mul(k, pubKey)      // ephemeral DH shared secret
		C := S.Add(S, M)                       // message blinded with secret

		Ks = append(Ks, K)
		Cs = append(Cs, C)
	}
	return Ks, Cs, pubKey
}

type fakeClient struct{}

func (fakeClient) GetNonce(access.Identity) (uint64, error) {
	return 0, nil
}
