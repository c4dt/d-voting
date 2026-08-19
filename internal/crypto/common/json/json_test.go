package json

import (
	"testing"

	"github.com/c4dt/d-voting/dela/crypto/common"
	"github.com/c4dt/d-voting/dela/serde"
	"github.com/c4dt/d-voting/dela/testing/fake"
	"github.com/stretchr/testify/require"
)

func TestAlgoFormat_Encode(t *testing.T) {
	algo := common.NewAlgorithm("fake")

	format := algoFormat{}
	ctx := serde.NewContext(fake.ContextEngine{})

	data, err := format.Encode(ctx, algo)
	require.NoError(t, err)
	require.Equal(t, `{"Name":"fake"}`, string(data))

	_, err = format.Encode(ctx, fake.Message{})
	require.EqualError(t, err, "unsupported message of type 'fake.Message'")

	_, err = format.Encode(fake.NewBadContext(), algo)
	require.EqualError(t, err, fake.Err("couldn't marshal"))
}

func TestFormat_Decode(t *testing.T) {
	format := algoFormat{}
	ctx := serde.NewContext(fake.ContextEngine{})

	algo, err := format.Decode(ctx, []byte(`{"Name": "fake","Data":[]}`))
	require.NoError(t, err)
	require.Equal(t, common.NewAlgorithm("fake"), algo)

	_, err = format.Decode(fake.NewBadContext(), []byte(`{}`))
	require.EqualError(t, err, fake.Err("couldn't deserialize algorithm"))
}
