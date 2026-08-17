package fastsync

import (
	"context"
	"fmt"
	"strconv"
	"testing"

	"github.com/c4dt/d-voting/internal/core/ordering/cosipbft/authority"
	"github.com/c4dt/d-voting/internal/core/ordering/cosipbft/blockstore"
	"github.com/c4dt/d-voting/internal/core/ordering/cosipbft/blocksync"
	"github.com/c4dt/d-voting/internal/core/ordering/cosipbft/pbft"
	otypes "github.com/c4dt/d-voting/internal/core/ordering/cosipbft/types"
	"github.com/c4dt/d-voting/internal/core/txn/signed"
	"github.com/c4dt/d-voting/internal/core/validation/simple"
	"github.com/c4dt/d-voting/internal/network/mino"
	"github.com/c4dt/d-voting/internal/network/mino/minoch"
	"github.com/c4dt/d-voting/internal/testing/fake"
	"github.com/stretchr/testify/require"
)

func TestDefaultSync_Basic(t *testing.T) {
	n := 20
	f := (n - 1) / 3
	num := 10

	syncs, genesis, roster := makeNodes(t, n)

	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	err := syncs[0].Sync(ctx, roster, Config{SplitMessageSize: 1})
	require.NoError(t, err)

	storeBlocks(t, syncs[0].blocks, num, genesis.GetHash().Bytes()...)

	// Test only a subset of the roster to prepare for the next test.
	for node := 1; node < n; node++ {
		// Send the sync call to the leader
		contact := roster.Take(mino.IndexFilter(0))
		if node >= 2*f+1 {
			// Now that there are 2f+1 nodes with the block, sync with
			// the whole roster.
			contact = roster
		}
		err = syncs[node].Sync(ctx, contact, Config{})
		require.NoError(t, err)
	}

	for i := 0; i < n; i++ {
		require.Equal(t, uint64(num), syncs[i].blocks.Len(), strconv.Itoa(i))
	}
}

func TestDefaultSync_SplitMessage(t *testing.T) {
	num := 10

	tests := []struct {
		sms  uint64
		msgs int
	}{
		{0, 1},
		{1, 10},
		{255, 10},
		{256, 5},
		{1024, 2},
		{2550, 1},
	}
	for _, test := range tests {
		syncs, genesis, roster := makeNodes(t, 2)

		ctx, cancel := context.WithCancel(t.Context())

		storeBlocks(t, syncs[0].blocks, num, genesis.GetHash().Bytes()...)

		syncsReceived := 0
		syncs[1].syncMessages = &syncsReceived
		err := syncs[1].Sync(ctx, roster, Config{SplitMessageSize: test.sms})
		require.NoError(t, err)
		require.Equal(t, test.msgs, syncsReceived)
		require.Equal(t, uint64(num), syncs[1].blocks.Len())
		cancel()
	}
}

// -----------------------------------------------------------------------------
// Utility functions

func makeNodes(t *testing.T, n int) ([]fastSync, otypes.Genesis, mino.Players) {
	manager := minoch.NewManager()

	syncs := make([]fastSync, n)
	addrs := make([]mino.Address, n)

	ro := authority.FromAuthority(fake.NewAuthority(3, fake.NewSigner))

	genesis, err := otypes.NewGenesis(ro)
	require.NoError(t, err)

	for i := 0; i < n; i++ {
		m := minoch.MustCreate(manager, fmt.Sprintf("node%d", i))

		addrs[i] = m.GetAddress()

		genstore := blockstore.NewGenesisStore()
		require.NoError(t, genstore.Set(genesis))

		blocks := blockstore.NewInMemory()
		blockFac := otypes.NewBlockFactory(simple.NewResultFactory(signed.NewTransactionFactory()))
		csFac := authority.NewChangeSetFactory(m.GetAddressFactory(), fake.PublicKeyFactory{})
		linkFac := otypes.NewLinkFactory(blockFac, fake.SignatureFactory{}, csFac)

		param := blocksync.SyncParam{
			Mino:            m,
			Blocks:          blocks,
			Genesis:         genstore,
			LinkFactory:     linkFac,
			ChainFactory:    otypes.NewChainFactory(linkFac),
			PBFT:            testSM{blocks: blocks},
			VerifierFactory: fake.VerifierFactory{},
		}

		syncs[i] = NewSynchronizer(param).(fastSync)
	}

	return syncs, genesis, mino.NewAddresses(addrs...)
}

// Create n new blocks and store them while creating appropriate links.
func storeBlocks(t *testing.T, blocks blockstore.BlockStore, n int, from ...byte) {
	prev := otypes.Digest{}
	copy(prev[:], from)

	for i := 0; i < n; i++ {
		block, err := otypes.NewBlock(simple.NewResult(nil), otypes.WithIndex(uint64(i)))
		require.NoError(t, err)

		link, err := otypes.NewBlockLink(prev, block,
			otypes.WithSignatures(fake.Signature{}, fake.Signature{}))
		require.NoError(t, err)

		err = blocks.Store(link)
		require.NoError(t, err)

		prev = block.GetHash()
	}
}

type testSM struct {
	pbft.StateMachine

	blocks blockstore.BlockStore
}

func (sm testSM) CatchUp(link otypes.BlockLink) error {
	err := sm.blocks.Store(link)
	if err != nil {
		return err
	}

	return nil
}
