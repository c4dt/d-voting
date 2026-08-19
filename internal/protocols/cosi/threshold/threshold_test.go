package threshold

import (
	"testing"

	"github.com/c4dt/d-voting/dela/cosi"
	"github.com/c4dt/d-voting/dela/crypto"
	"github.com/c4dt/d-voting/dela/crypto/bls"
	"github.com/c4dt/d-voting/dela/mino"
	"github.com/c4dt/d-voting/dela/mino/minoch"
	"github.com/c4dt/d-voting/dela/serde"
	"github.com/c4dt/d-voting/dela/testing/fake"
	"github.com/stretchr/testify/require"
)

func TestThreshold_Scenario_Basic(t *testing.T) {
	manager := minoch.NewManager()

	m1 := minoch.MustCreate(manager, "A")
	m2 := minoch.MustCreate(manager, "B")

	ca := fake.NewAuthorityFromMino(bls.Generate, m1, m2)
	c1 := NewThreshold(m1, ca.GetSigner(0).(crypto.AggregateSigner))
	c1.SetThreshold(OneThreshold)

	actor, err := c1.Listen(fakeReactor{})
	require.NoError(t, err)

	c2 := NewThreshold(m2, ca.GetSigner(1).(crypto.AggregateSigner))
	_, err = c2.Listen(fakeReactor{err: fake.GetError()})
	require.NoError(t, err)

	ctx := t.Context()
	sig, err := actor.Sign(ctx, fake.Message{}, ca)
	require.NoError(t, err)
	require.NotNil(t, sig)

	verifier, err := c1.GetVerifierFactory().FromAuthority(ca)
	require.NoError(t, err)
	require.NoError(t, verifier.Verify([]byte{0xff}, sig))
}

func TestDefaultThreshold(t *testing.T) {
	require.Equal(t, 2, defaultThreshold(2))
	require.Equal(t, 5, defaultThreshold(5))
}

func TestOneThreshold(t *testing.T) {
	require.Equal(t, 0, OneThreshold(-10))
	require.Equal(t, 0, OneThreshold(0))
	require.Equal(t, 5, OneThreshold(6))
}

func TestByzantineThreshold(t *testing.T) {
	require.Equal(t, 0, ByzantineThreshold(-10))
	require.Equal(t, 0, ByzantineThreshold(0))
	require.Equal(t, 2, ByzantineThreshold(2))
	require.Equal(t, 3, ByzantineThreshold(4))
	require.Equal(t, 5, ByzantineThreshold(7))
}

func TestThreshold_GetSigner(t *testing.T) {
	c := &Threshold{signer: fake.NewAggregateSigner()}
	require.NotNil(t, c.GetSigner())
}

func TestThreshold_GetPublicKeyFactory(t *testing.T) {
	c := &Threshold{signer: fake.NewAggregateSigner()}
	require.NotNil(t, c.GetPublicKeyFactory())
}

func TestThreshold_GetSignatureFactory(t *testing.T) {
	c := &Threshold{signer: fake.NewAggregateSigner()}
	require.NotNil(t, c.GetSignatureFactory())
}

func TestThreshold_SetThreshold(t *testing.T) {
	c := NewThreshold(fake.Mino{}, nil)

	c.SetThreshold(nil)
	require.NotNil(t, c.thresholdFn.Load())

	c.SetThreshold(ByzantineThreshold)
	require.Equal(t, ByzantineThreshold(999), c.thresholdFn.Load().(cosi.Threshold)(999))
}

func TestThreshold_Listen(t *testing.T) {
	c := &Threshold{
		mino:   fake.Mino{},
		signer: fake.NewAggregateSigner(),
	}

	actor, err := c.Listen(fakeReactor{})
	require.NoError(t, err)
	require.NotNil(t, actor)
}

// -----------------------------------------------------------------------------
// Utility functions

type fakeReactor struct {
	fake.MessageFactory

	err error
}

func (h fakeReactor) Invoke(addr mino.Address, in serde.Message) ([]byte, error) {
	return []byte{0xff}, h.err
}
