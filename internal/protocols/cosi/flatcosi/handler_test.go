package flatcosi

import (
	"testing"

	"github.com/c4dt/d-voting/dela/cosi"
	"github.com/c4dt/d-voting/dela/crypto/bls"
	"github.com/c4dt/d-voting/dela/mino"
	"github.com/c4dt/d-voting/dela/serde"
	"github.com/c4dt/d-voting/dela/testing/fake"
	"github.com/stretchr/testify/require"
)

func TestHandler_Process(t *testing.T) {
	signer := bls.NewSigner()

	h := newHandler(signer, fakeReactor{})
	req := mino.Request{
		Message: cosi.SignatureRequest{Value: fake.Message{}},
	}

	msg, err := h.Process(req)
	require.NoError(t, err)

	resp, ok := msg.(cosi.SignatureResponse)
	require.True(t, ok)

	err = signer.GetPublicKey().Verify(testValue, resp.Signature)
	require.NoError(t, err)
}

func TestHandler_InvalidMessage_Process(t *testing.T) {
	h := newHandler(fake.NewSigner(), fakeReactor{})

	resp, err := h.Process(mino.Request{Message: fake.Message{}})
	require.EqualError(t, err, "invalid message type 'fake.Message'")
	require.Nil(t, resp)
}

func TestHandler_DenyingReactor_Process(t *testing.T) {
	h := newHandler(fake.NewSigner(), fakeReactor{err: fake.GetError()})

	req := mino.Request{
		Message: cosi.SignatureRequest{Value: fake.Message{}},
	}

	_, err := h.Process(req)
	require.EqualError(t, err, fake.Err("couldn't hash message"))
}

func TestHandler_FailSign_Process(t *testing.T) {
	h := newHandler(fake.NewBadSigner(), fakeReactor{})

	req := mino.Request{
		Message: cosi.SignatureRequest{Value: fake.Message{}},
	}

	_, err := h.Process(req)
	require.EqualError(t, err, fake.Err("couldn't sign"))
}

// -----------------------------------------------------------------------------
// Utility functions

var testValue = []byte{0xab}

type fakeReactor struct {
	err error
}

func (h fakeReactor) Invoke(mino.Address, serde.Message) ([]byte, error) {
	return testValue, h.err
}

func (h fakeReactor) Deserialize(serde.Context, []byte) (serde.Message, error) {
	return fake.Message{}, h.err
}
