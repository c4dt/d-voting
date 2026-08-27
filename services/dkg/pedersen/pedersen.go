package pedersen

import (
	"encoding/hex"
	"encoding/json"
	"math/rand"
	"sync"
	"time"

	"go.dedis.ch/dela/core/store/kv"
	"go.dedis.ch/dela/core/txn"
	"go.dedis.ch/dela/core/txn/pool"
	"go.dedis.ch/dela/crypto"

	"go.dedis.ch/dela"
	"go.dedis.ch/dela/core/ordering"

	"github.com/c4dt/d-voting/contracts/evoting"
	etypes "github.com/c4dt/d-voting/contracts/evoting/types"
	"github.com/rs/zerolog"

	"github.com/c4dt/d-voting/internal/tracing"
	"github.com/c4dt/d-voting/services/dkg"

	"go.dedis.ch/dela/mino"
	"go.dedis.ch/dela/serde"
	jsonserde "go.dedis.ch/dela/serde/json"
	"go.dedis.ch/kyber/v3"
	"go.dedis.ch/kyber/v3/suites"
	"golang.org/x/net/context"
	"golang.org/x/xerrors"

	// Register the JSON format for the form
	_ "github.com/c4dt/d-voting/contracts/evoting/json"

	// dela Pedersen DKG
	"go.dedis.ch/dela/cosi/threshold"
	delaPedersen "go.dedis.ch/dela/dkg/pedersen"
)

// BucketName is the name of the bucket in the database.
const BucketName = "dkgmap"

// suite is the Kyber suite for Pedersen.
var suite = suites.MustFind("Ed25519")

var (
	// protocolNameSetup denotes the value of the protocol span tag
	// associated with the `dkg-setup` protocol.
	protocolNameSetup = "dkg-setup"
	// protocolNameDecrypt denotes the value of the protocol span tag
	// associated with the `dkg-decrypt` protocol.
	protocolNameDecrypt = "dkg-decrypt"
)

const (
	setupTimeout   = time.Second * 300
	decryptTimeout = time.Second * 100
)

// Pedersen allows one to initialize a new DKG protocol.
//
// - implements dkg.DKG
type Pedersen struct {
	sync.RWMutex

	mino    mino.Mino
	service ordering.Service
	formFac serde.Factory
	pool    pool.Pool
	signer  crypto.Signer
	actors  map[string]dkg.Actor
	db      kv.DB
}

// NewPedersen returns a new DKG Pedersen factory
func NewPedersen(m mino.Mino, service ordering.Service,
	db kv.DB, pool pool.Pool,
	formFac serde.Factory, signer crypto.Signer) *Pedersen {

	actors := make(map[string]dkg.Actor)

	return &Pedersen{
		mino:    m,
		service: service,
		pool:    pool,
		actors:  actors,
		signer:  signer,
		formFac: formFac,
		db:      db,
	}
}

// Listen implements dkg.DKG. It must be called on each node that participates
// in the DKG.
func (s *Pedersen) Listen(formIDBuf []byte, txmngr txn.Manager) (dkg.Actor, error) {

	formID := hex.EncodeToString(formIDBuf)

	formBuf, err := s.service.GetStore().Get(formIDBuf)
	if err != nil {
		return nil, xerrors.Errorf("While looking for form: %v", err)
	}
	if len(formBuf) == 0 {
		return nil, xerrors.Errorf("form %s was not found", formID)
	}

	actor, exists := s.GetActor(formIDBuf)
	if exists {
		return actor, xerrors.Errorf("actor already exists for formID %s", formID)
	}

	return s.NewActor(formIDBuf, s.pool, txmngr, NewHandlerData())
}

// NewActor initializes a dkg.Actor with an RPC specific to the form with
// the given keypair
func (s *Pedersen) NewActor(formIDBuf []byte, pool pool.Pool, txmngr txn.Manager,
	handlerData HandlerData) (dkg.Actor,
	error) {

	// hex-encoded string
	formID := hex.EncodeToString(formIDBuf)

	ctx := jsonserde.NewContext()

	status := &dkg.Status{Status: dkg.Initialized}

	// Instead of creating our own Pedersen handler, we create a dela Pedersen
	// actor on a Mino segment dedicated to this form. dela's SetupWithPlayers
	// discovers the DKG public keys of the roster internally.
	no := s.mino.WithSegment(formID)

	// Create a fresh dela Pedersen factory on the segmented Mino.
	delaFactory, _ := delaPedersen.NewPedersen(no)

	// Listen on dela's DKG RPC (fixed name "dkg") on the same segment.
	delaActorIface, err := delaFactory.Listen()
	if err != nil {
		return nil, xerrors.Errorf("failed to listen on dela DKG: %v", err)
	}

	// Assert to the concrete type so we can use DecryptShare and
	// MarshalBinary, which are not on the generic dkg.Actor interface.
	delaActor, ok := delaActorIface.(*delaPedersen.Actor)
	if !ok {
		return nil, xerrors.Errorf("expected *pedersen.Actor, got %T", delaActorIface)
	}

	log := dela.Logger.With().Str("role", "DKG actor").Logger()

	a := &Actor{
		protocol: delaActor,
		service:  s.service,
		context:  ctx,
		formFac:  s.formFac,
		formID:   formID,
		status:   status,
		log:      log,
		db:       s.db,
		txmnger:  txmngr,
		pool:     pool,
		signer:   s.signer,
	}

	evoting.PromFormDkgStatus.WithLabelValues(formID).Set(float64(dkg.Initialized))

	s.Lock()
	defer s.Unlock()
	s.actors[formID] = a

	return a, a.store()
}

// GetActor implements dkg.DKG
func (s *Pedersen) GetActor(formIDBuf []byte) (dkg.Actor, bool) {
	s.RLock()
	defer s.RUnlock()
	actor, exists := s.actors[hex.EncodeToString(formIDBuf)]
	return actor, exists
}

func (s *Pedersen) ReadActors(txmngr txn.Manager) error {
	// Use dkgMap to fill the actors map
	return s.db.View(func(tx kv.ReadableTx) error {
		bucket := tx.GetBucket([]byte(BucketName))
		if bucket == nil {
			return nil
		}

		return bucket.ForEach(func(formIDBuf, handlerDataBuf []byte) error {

			handlerData := HandlerData{}
			err := json.Unmarshal(handlerDataBuf, &handlerData)
			if err != nil {
				return err
			}

			_, err = s.NewActor(formIDBuf, s.pool, txmngr, handlerData)
			if err != nil {
				return err
			}

			return nil
		})
	})
}

// protocolActor is the narrow interface the adapter needs from a dela DKG
// actor. Keeping it small lets unit tests fake dela instead of implementing
// the full dela dkg.Actor interface.
type protocolActor interface {
	// SetupWithPlayers discovers the DKG public key of every player over
	// Mino and then runs setup.
	SetupWithPlayers(players mino.Players, threshold int) (kyber.Point, error)
	// GetPublicKey returns the collective public key.
	GetPublicKey() (kyber.Point, error)
	// Encrypt encrypts the message into a K and a slice of ciphertext points.
	Encrypt(message []byte) (kyber.Point, []kyber.Point, error)
	// DecryptShare computes this actor's local partial decryption of one
	// ciphertext (K, C) without exposing the private share.
	DecryptShare(K, C kyber.Point) (int, kyber.Point, error)
	// MarshalBinary exports the stable protocol state as opaque bytes.
	MarshalBinary() ([]byte, error)
}

// Actor allows one to perform DKG operations like encrypt/decrypt a message
//
// - implements dkg.Actor
type Actor struct {
	protocol protocolActor
	service  ordering.Service
	context  serde.Context
	formFac  serde.Factory
	formID   string
	status   *dkg.Status
	log      zerolog.Logger
	db       kv.DB
	txmnger  txn.Manager
	pool     pool.Pool
	signer   crypto.Signer
}

func (a *Actor) setErr(err error, args map[string]interface{}) {
	*a.status = dkg.Status{
		Status: dkg.Failed,
		Err:    err,
		Args:   args,
	}

	evoting.PromFormDkgStatus.WithLabelValues(a.formID).Set(float64(dkg.Failed))
}

// Setup implements dkg.Actor. It initializes the DKG protocol across all
// participating nodes. This function updates the actor's status in case of
// error to allow asynchronous call of this function.
func (a *Actor) Setup() (kyber.Point, error) {
	a.log.Info().Msg("setup")

	form, err := etypes.FormFromStore(a.context, a.formFac, a.formID, a.service.GetStore())
	if err != nil {
		err := xerrors.Errorf("failed to get form: %v", err)
		a.setErr(err, nil)
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), setupTimeout)
	defer cancel()
	ctx = context.WithValue(ctx, tracing.ProtocolKey, protocolNameSetup)

	// dela's SetupWithPlayers discovers the DKG public keys of the roster
	// internally and runs setup. We no longer need our own discovery RPC.
	threshold := threshold.ByzantineThreshold(form.Roster.Len())

	pubKey, err := a.protocol.SetupWithPlayers(form.Roster, threshold)
	if err != nil {
		err := xerrors.Errorf("failed to setup dela DKG: %v", err)
		a.setErr(err, nil)
		return nil, err
	}

	*a.status = dkg.Status{Status: dkg.Setup}
	evoting.PromFormDkgStatus.WithLabelValues(a.formID).Set(float64(dkg.Setup))

	return pubKey, a.store()
}

func (a *Actor) store() error {
	return storeHandler(a.formID, a.db, a)
}
func storeHandler(formID string, db kv.DB, a *Actor) error {
	return db.Update(func(tx kv.WritableTx) error {
		formIDBuf, err := hex.DecodeString(formID)
		if err != nil {
			return err
		}

		bucket, err := tx.GetBucketOrCreate([]byte(BucketName))
		if err != nil {
			return err
		}

		actorBuf, err := a.MarshalJSON()
		if err != nil {
			return err
		}

		return bucket.Set(formIDBuf, actorBuf)
	})
}

// GetPublicKey implements dkg.Actor
func (a *Actor) GetPublicKey() (kyber.Point, error) {
	return a.protocol.GetPublicKey()
}

// Encrypt implements dkg.Actor. It uses the DKG public key to encrypt a
// message.
func (a *Actor) Encrypt(message []byte) (K, C kyber.Point, remainder []byte,
	err error) {

	// dela returns (K, Cs []kyber.Point); d-voting expects (K, C, remainder).
	return encryptShim(a.protocol.Encrypt, message)
}

// ComputePubshares implements dkg.Actor. It computes the local partial
// decryptions of the shuffled ballots and publishes them on the chain.
func (a *Actor) ComputePubshares() error {
	shuffleInstances, err := a.getShuffleIfValid()
	if err != nil {
		return xerrors.Errorf("failed to check if the shuffle is over: %v", err)
	}

	numberOfShuffles := len(shuffleInstances)
	numberOfBallots := len(shuffleInstances[numberOfShuffles-1].ShuffledBallots)
	publicShares := make([][]etypes.Pubshare, numberOfBallots)

	for i, ballot := range shuffleInstances[numberOfShuffles-1].ShuffledBallots {
		ballotShares := make([]etypes.Pubshare, len(ballot))

		for j, ciphertext := range ballot {
			index, partial, err := a.protocol.DecryptShare(ciphertext.K, ciphertext.C)
			if err != nil {
				return xerrors.Errorf("failed to compute decrypt share: %v", err)
			}

			ballotShares[j] = partial
			_ = index
		}

		publicShares[i] = ballotShares
	}

	err = a.txmnger.Sync()
	if err != nil {
		return xerrors.Errorf("failed to sync manager: %v", err)
	}

	// loop until our transaction has been accepted, or enough nodes submitted
	// their pubShares
	for {
		form, err := etypes.FormFromStore(a.context, a.formFac, a.formID, a.service.GetStore())
		if err != nil {
			return xerrors.Errorf("could not get the form: %v", err)
		}

		nbrSubmissions := len(form.PubsharesUnits.Pubshares)

		if nbrSubmissions >= form.ShuffleThreshold {
			dela.Logger.Info().Msgf("decryption possible with shares from %d nodes",
				nbrSubmissions)
			return nil
		}

		// Use the share index from the first ciphertext as our node index.
		_, _, err = a.protocol.DecryptShare(
			shuffleInstances[numberOfShuffles-1].ShuffledBallots[0][0].K,
			shuffleInstances[numberOfShuffles-1].ShuffledBallots[0][0].C,
		)
		if err != nil {
			return xerrors.Errorf("failed to get share index: %v", err)
		}

		tx, err := makeTx(a.context, &form, publicShares, 0,
			a.txmnger, a.signer)
		if err != nil {
			return xerrors.Errorf("failed to make tx: %v", err)
		}

		watchTimeout := 4 + rand.Intn(form.ShuffleThreshold)
		watchCtx, cancel := context.WithTimeout(context.Background(),
			time.Duration(watchTimeout)*time.Second)

		events := a.service.Watch(watchCtx)

		err = a.pool.Add(tx)
		if err != nil {
			cancel()
			return xerrors.Errorf("failed to add transaction to the pool: %v", err)
		}

		accepted, msg := watchTx(events, tx.GetID())

		if accepted {
			dela.Logger.Info().Msgf("pubShares accepted on the chain")
			return nil
		}

		err = a.txmnger.Sync()
		if err != nil {
			cancel()
			return xerrors.Errorf("failed to sync manager: %v", err)
		}

		dela.Logger.Info().Msgf("submission of pubShares denied: %s", msg)

		cancel()
	}
}

// MarshalJSON implements dkg.Actor. It exports the data relevant to an Actor
// that is meant to be persistent. The opaque dela snapshot bytes are wrapped
// in a versioned HandlerData record.
func (a *Actor) MarshalJSON() ([]byte, error) {
	snapshot, err := a.protocol.MarshalBinary()
	if err != nil {
		return nil, xerrors.Errorf("failed to marshal dela DKG snapshot: %v", err)
	}

	data := HandlerData{
		Version:  1,
		Snapshot: snapshot,
	}

	return json.Marshal(data)
}

// getShuffleIfValid allows checking if enough shuffles have been made on the
// ballots.
func (a *Actor) getShuffleIfValid() ([]etypes.ShuffleInstance, error) {
	form, err := etypes.FormFromStore(a.context, a.formFac, a.formID, a.service.GetStore())
	if err != nil {
		return nil, xerrors.Errorf("could not get the form: %v", err)
	}

	if len(form.ShuffleInstances) == 0 {
		return nil, xerrors.New("form has no shuffles")
	}

	if form.Status != etypes.ShuffledBallots {
		return nil, xerrors.New("ballots have not been shuffled")
	}

	return form.ShuffleInstances, nil
}

//

// Status implements dkg.Actor
func (a *Actor) Status() dkg.Status {
	return *a.status
}
