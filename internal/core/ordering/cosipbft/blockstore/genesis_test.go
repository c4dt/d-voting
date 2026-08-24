package blockstore

import (
	"testing"

	"github.com/c4dt/d-voting/internal/core/ordering/cosipbft/authority"
	"github.com/c4dt/d-voting/internal/core/ordering/cosipbft/types"
	"github.com/c4dt/d-voting/internal/core/store/kv"
	"github.com/c4dt/d-voting/internal/testing/dela/fake"
	"github.com/stretchr/testify/require"
)

func TestCachedGenesis_Get(t *testing.T) {
	store := NewGenesisStore().(*cachedGenesis)

	ro := authority.FromAuthority(fake.NewAuthority(3, fake.NewSigner))

	_, err := store.Get()
	require.EqualError(t, err, "missing genesis block")

	block, err := types.NewGenesis(ro)
	require.NoError(t, err)

	store.set = true
	store.genesis = block

	genesis, err := store.Get()
	require.NoError(t, err)
	require.Equal(t, block, genesis)
}

func TestCachedGenesis_Set(t *testing.T) {
	ro := authority.FromAuthority(fake.NewAuthority(3, fake.NewSigner))

	block, err := types.NewGenesis(ro)
	require.NoError(t, err)

	store := NewGenesisStore().(*cachedGenesis)

	err = store.Set(block)
	require.NoError(t, err)
	require.True(t, store.set)

	err = store.Set(block)
	require.EqualError(t, err, "genesis block is already set")
}

func TestCachedGenesis_Exists(t *testing.T) {
	store := NewGenesisStore()

	require.False(t, store.Exists())

	store.Set(types.Genesis{})
	require.True(t, store.Exists())
}

func TestGenesisDiskStore_Load(t *testing.T) {
	db, clean := makeDB(t)
	defer clean()

	store := NewGenesisDiskStore(db, makeFac())

	err := store.Load()
	require.NoError(t, err)
	require.False(t, store.set)

	err = store.Set(makeGenesis(t))
	require.NoError(t, err)

	// Reset the store.
	store = NewGenesisDiskStore(db, makeFac())

	err = store.Load()
	require.NoError(t, err)
	require.True(t, store.set)

	store.fac = fake.NewBadMessageFactory()
	err = store.Load()
	require.EqualError(t, err, fake.Err("malformed value"))

	store.fac = fake.MessageFactory{}
	err = store.Load()
	require.EqualError(t, err, "unsupported message 'fake.Message'")
}

func TestGenesisDiskStore_Set(t *testing.T) {
	db, clean := makeDB(t)
	defer clean()

	store := NewGenesisDiskStore(db, makeFac())

	err := store.Set(makeGenesis(t))
	require.NoError(t, err)

	var data []byte
	db.View(func(tx kv.ReadableTx) error {
		data = tx.GetBucket(genesisBucket).Get(genesisKey)
		return nil
	})

	require.NotEmpty(t, data)

	store = NewGenesisDiskStore(badDB{}, makeFac())
	err = store.Set(makeGenesis(t))
	require.EqualError(t, err, fake.Err("store failed: bucket"))

	store.db = badDB{bucket: badBucket{}}
	err = store.Set(makeGenesis(t))
	require.EqualError(t, err, fake.Err("store failed: while writing to bucket"))

	store.context = fake.NewBadContext()
	err = store.Set(makeGenesis(t))
	require.Error(t, err)
	require.Contains(t, err.Error(), "failed to serialize genesis: ")
}

// -----------------------------------------------------------------------------
// Utility functions
func makeFac() types.GenesisFactory {
	authFac := authority.NewFactory(fake.AddressFactory{}, fake.PublicKeyFactory{})

	return types.NewGenesisFactory(authFac)
}

func makeGenesis(t *testing.T) types.Genesis {
	ro := authority.FromAuthority(fake.NewAuthority(1, fake.NewSigner))

	genesis, err := types.NewGenesis(ro)
	require.NoError(t, err)

	return genesis
}

type badBucket struct {
	kv.Bucket
}

func (badBucket) Set(key, value []byte) error {
	return fake.GetError()
}

type badTx struct {
	kv.WritableTx

	bucket kv.Bucket
}

func (tx badTx) GetBucketOrCreate(name []byte) (kv.Bucket, error) {
	if tx.bucket != nil {
		return tx.bucket, nil
	}

	return nil, fake.GetError()
}

type badDB struct {
	kv.DB

	bucket kv.Bucket
}

func (db badDB) Update(fn func(kv.WritableTx) error) error {
	return fn(badTx{bucket: db.bucket})
}
